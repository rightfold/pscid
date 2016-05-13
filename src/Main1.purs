module Main where

import Blessed
import Node.Process as P
import Control.Monad.Aff (Aff, runAff)
import Control.Monad.Eff (Eff)
import Data.Array ((!!))
import Data.Either (Either(Right, Left))
import Data.Maybe (Maybe(Just))
import Data.Maybe.Unsafe (fromJust)
import Data.Options ((:=))
import Prelude (map, pure, unit, const, (<>), bind, Unit)
import PscIde (pursuitCompletion, NET, cwd)
import PscIde.Command (PursuitCompletion(PursuitCompletion), Message(Message))

type Screens =
  { mainScreen   :: Element Screen
  , searchScreen :: Element Form
  , resultScreen :: Element Form
  }

type BlessEff e = Eff ( bless :: BLESS | e)

mkScreens
  :: forall e
  . Element Screen
  -> Element Form
  -> Element Form
  -> BlessEff e Screens
mkScreens mainScreen searchScreen resultScreen = do
  append mainScreen searchScreen
  append mainScreen resultScreen
  pure {mainScreen, searchScreen, resultScreen}

hideScreens :: forall e. Screens -> BlessEff e Unit
hideScreens {searchScreen, resultScreen} = do
  hide searchScreen
  hide resultScreen

main :: forall e. Eff ( bless :: BLESS, process :: P.PROCESS, net :: NET | e) Unit
main = do
  s <- screen defaultScreenOptions
  title <- text (defaultTextOptions
                     <> content := Just "PURR"
                     <> top     := Just (colDistance 0)
                     <> height  := Just (colDistance 1))
  append s title
  search <- form (defaultFormOptions
                         <> label  := Just "Pursuit"
                         <> bottom := Just (colDistance 0)
                         <> width  := Just (percentDistance 100)
                         <> height := Just (colDistance 2))
  searchInput <- textbox (defaultTextboxOptions
                           <> bottom := Just (colDistance 0)
                           <> left   := Just (colDistance 2)
                           <> height := Just (colDistance 1))
  append search searchInput
  pursuitResult <- form (defaultFormOptions
                      <> label  := Just "Pursuit Results"
                      <> top := Just (colDistance 2)
                      <> width  := Just (percentDistance 100))

  psList <- pursuitList
  psDetail <- detailView
  append pursuitResult psList
  append pursuitResult psDetail
  screens <- mkScreens s search pursuitResult
  hideScreens screens

  key s "q" (P.exit 0)
  key s "p" do
    hideScreens screens
    show screens.searchScreen
    clearValue searchInput
    render screens.mainScreen
    readInput searchInput (\i -> do
                              runAff' (pursuitCompletion 4243 i) \cs -> case cs of
                                Left _ -> pure unit
                                Right completions -> do
                                  let items = map showPC completions
                                  setItems psList items
                                  onSelect psList \ix -> do
                                    setContent psDetail (showPrettyPC (fromJust (completions !! ix)))
                                    render screens.mainScreen
                                  hide search
                                  show pursuitResult
                                  render s
                                  focus psList
                              hide screens.searchScreen
                              render s)
  key s "l" do
    runAff' (cwd 4243) \c -> case c of
      Left err -> pure unit
      Right (Message path) -> do
        let values = ["Waow", "Rofl", "Copter", path]
        setItems psList values
        hide search
        show pursuitResult
        render s
        focus psList
  render s

showPC :: PursuitCompletion -> String
showPC (PursuitCompletion {type': ident, identifier: modu, module': ty, package}) =
  "(" <> package <> ") " <> modu <> "." <> ident <> " :: " <> ty

showPrettyPC :: PursuitCompletion -> String
showPrettyPC (PursuitCompletion {type': ident, identifier: modu, module': ty, package}) =
  "PACKAGE: " <> package <> "\nMODULE: " <> modu <> "\nIDENTIFIER: " <> ident <> "\nTYPE: " <> ty

runAff' :: forall e a. Aff e a -> (a -> Eff e Unit) -> Eff e Unit
runAff' a s = runAff (const (pure unit)) s a

detailView :: forall e. Eff (bless :: BLESS | e) (Element Text)
detailView =
  text (defaultTextOptions
        <> top := Just (colDistance 7))

pursuitList :: forall e. Eff (bless :: BLESS | e) (Element (List Unit))
pursuitList =
  list (defaultListOptions
        <> top         := Just (colDistance 1)
        <> height      := Just (colDistance 5)
        <> scrollable  := Just true
        <> width       := Just (percentDistance 100)
        <> interactive := Just true
        <> style       := Just {fg: "blue", bg: "black"})