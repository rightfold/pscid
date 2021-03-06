module Main where

import Prelude
import Control.Monad.Reader.Class as Reader
import Data.String as String
import Node.Process as Process
import Control.Monad.Aff (runAff, later', attempt)
import Control.Monad.Aff.AVar (AVAR)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Console (log, CONSOLE)
import Control.Monad.Eff.Exception (EXCEPTION)
import Control.Monad.Eff.Random (RANDOM)
import Control.Monad.Eff.Ref (writeRef, readRef, Ref, newRef, REF)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff)
import Control.Monad.Reader (class MonadAsk)
import Control.Monad.Reader.Trans (ReaderT, runReaderT)
import Control.Monad.ST (runST)
import Data.Argonaut (Json)
import Data.Array (concatMap, head, null)
import Data.Either (isRight, Either(..), either)
import Data.Function.Eff (runEffFn2, EffFn2)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Newtype (unwrap, wrap)
import Data.String (Pattern(..))
import Node.ChildProcess (CHILD_PROCESS)
import Node.FS (FS)
import PscIde (sendCommandR, load, cwd, NET)
import PscIde.Command (Command(..), Message(..))
import Pscid.Console (owl, clearConsole, suggestionHint, startScreen)
import Pscid.Error (catchLog, noSourceDirectoryError)
import Pscid.Keypress (Key(..), onKeypress, initializeKeypresses)
import Pscid.Options (PscidSettings, optionParser)
import Pscid.Process (execCommand)
import Pscid.Psa (filterWarnings, PsaError, parseErrors, psaPrinter)
import Pscid.Server (restartServer, startServer', stopServer')
import Pscid.Util (launchAffVoid, both, (∘))
import Suggest (applySuggestions)

type PscidEffects = PscidEffects' ()

type PscidEffects' e =
  ( cp ∷ CHILD_PROCESS
  , console ∷ CONSOLE
  , net ∷ NET
  , avar ∷ AVAR
  , fs ∷ FS
  , process ∷ Process.PROCESS
  , random ∷ RANDOM
  , ref ∷ REF
  | e
  )

newtype Pscid a = Pscid (ReaderT (PscidSettings Int) (Eff PscidEffects) a)
derive newtype instance functorPscid ∷ Functor Pscid
derive newtype instance bindPscid ∷ Bind Pscid
derive newtype instance monadPscid ∷ Monad Pscid
derive newtype instance monadAskPscid ∷ MonadAsk (PscidSettings Int) Pscid
instance monadEffPscid ∷ MonadEff e Pscid where
  liftEff f = Pscid (liftEff (unsafeCoerceEff f))

runPscid ∷ ∀ a. Pscid a → PscidSettings Int → Eff PscidEffects a
runPscid (Pscid f) e = runReaderT f e

newtype State = State { errors ∷ Array PsaError }

emptyState ∷ State
emptyState = State { errors: [] }

main ∷ Eff (PscidEffects' (err ∷ EXCEPTION)) Unit
main = launchAffVoid do
  config@{ port, sourceDirectories } ← unwrap <$> liftEff optionParser
  when (null sourceDirectories) (liftEff noSourceDirectoryError)
  stateRef ← liftEff (newRef emptyState)
  liftEff (log "Starting psc-ide-server")
  r ← attempt (startServer' port)
  case r of
    Right (Right port') → do
      let config' = wrap (config { port = port' })
      Message directory ← later' 500 do
        load port' [] []
        res ← cwd port'
        case res of
          Right d → pure d
          Left err → liftEff do
            log err
            Process.exit 1
      liftEff do
        runEffFn2 gaze
          (concatMap (fileGlob directory) sourceDirectories)
          (\d → runPscid (triggerRebuild stateRef d) config')
        clearConsole
        initializeKeypresses
        onKeypress (\k → runPscid (keyHandler stateRef k) config')
        log ("Watching " <> directory <> " on port " <> show port')
        startScreen
    _ → liftEff (log "Failed to start psc-ide-server")

-- | Given a base directory and a directory, appends the globs necessary to
-- | match all PureScript and JavaScript source files inside that directory
fileGlob ∷ String → String → Array String
fileGlob base dir =
  let go x = base <> "/" <> dir <> "/**/*" <> x
  in go <$> [".purs", ".js"]

keyHandler ∷ Ref State → Key → Pscid Unit
keyHandler stateRef k = do
  {port, buildCommand, testCommand} ← ask
  case k of
    Key {ctrl: false, name: "b", meta: false, shift: false} →
      liftEff (execCommand "Build" buildCommand)
    Key {ctrl: false, name: "t", meta: false, shift: false} →
      liftEff (execCommand "Test" testCommand)
    Key {ctrl: false, name: "r", meta: false, shift: false} → liftEff do
      clearConsole
      catchLog "Failed to restart server" $ launchAffVoid do
        restartServer port
        load port [] []
      log owl
    Key {ctrl: false, name: "s", meta: false, shift: false} → liftEff do
      State state ← readRef stateRef
      case head state.errors of
        Nothing →
          log "No suggestions available"
        Just e →
          catchLog "Couldn't apply suggestion." (runST (applySuggestions [e]))
    Key {ctrl: false, name: "q", meta: false, shift: false} →
      liftEff (log "Bye!" <* runAff exit exit (stopServer' port))
    Key {ctrl: true, name: "c", meta: false, shift: false} →
      liftEff (log "Press q to exit")
    Key {ctrl, name, meta, shift} →
      liftEff (log name)
  where
    exit ∷ ∀ a eff. a → Eff (process ∷ Process.PROCESS | eff) Unit
    exit = const (Process.exit 0)

triggerRebuild ∷ Ref State → String → Pscid Unit
triggerRebuild stateRef file = do
  {port, testCommand, testAfterRebuild, censorCodes} ← ask
  let fileName = changeExtension file "purs"
  liftEff ∘ catchLog "We couldn't talk to the server" $ launchAffVoid do
    result ← sendCommandR port (RebuildCmd fileName)
    case result of
      Left _ → liftEff (log "We couldn't talk to the server")
      Right errs → liftEff do
        parsedErrors ← handleRebuildResult fileName censorCodes errs
        writeRef stateRef (State {errors: parsedErrors})
        case head parsedErrors >>= _.suggestion of
          Nothing → pure unit
          Just s → suggestionHint
        when (testAfterRebuild && isRight errs)
          (execCommand "Test" testCommand)

changeExtension ∷ String → String → String
changeExtension s ex =
  case String.lastIndexOf (Pattern ".") s of
    Nothing →
      s
    Just ix →
      String.take ix s <> "." <> ex

handleRebuildResult
  ∷ ∀ e
  . String
  → Array String
  → Either Json Json
  → Eff (console ∷ CONSOLE, fs ∷ FS | e) (Array PsaError)
handleRebuildResult file censorCodes result = do
  clearConsole
  log ("Checking " <> file)
  case both parseErrors result of
    Right warnings →
      either
        (\_ → log "Failed to parse warnings" $> [])
        (\e → psaPrinter owl false e $> e)
        (filterWarnings censorCodes <$> warnings)
    Left errors →
      either
        (\_ → log "Failed to parse errors" $> [])
        (\e → psaPrinter owl true e $> e)
        errors

foreign import gaze
  ∷ ∀ eff
  . EffFn2 (fs ∷ FS | eff)
      (Array String)
      (String → Eff (fs ∷ FS | eff) Unit)
      Unit

ask ∷ Pscid { port ∷ Int
             , buildCommand ∷ String
             , testCommand ∷ String
             , testAfterRebuild ∷ Boolean
             , sourceDirectories ∷ Array String
             , censorCodes ∷ Array String
             }
ask = unwrap <$> Reader.ask
