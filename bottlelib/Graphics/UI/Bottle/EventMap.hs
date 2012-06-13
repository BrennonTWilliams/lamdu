{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE TemplateHaskell, FlexibleInstances, MultiParamTypeClasses, GeneralizedNewtypeDeriving, DeriveDataTypeable, DeriveFunctor #-}
module Graphics.UI.Bottle.EventMap
  ( EventMap
  , EventType(..)
  , IsPress(..), ModKey(..)
  , Event
  , module Graphics.UI.GLFW.ModState
  , module Graphics.UI.GLFW.Events
  , lookup
  , charEventMap, allCharsEventMap, simpleCharsEventMap
  , singleton, keyPress, keyPresses
  , delete, filterChars
  , Key(..), charKey, Doc, eventMapDocs
  ) where

import Control.Arrow((***), (&&&))
import Control.Monad(mplus)
import Data.Char(toLower, toUpper)
import Data.List(isPrefixOf)
import Data.Map(Map)
import Data.Maybe(isNothing)
import Data.Monoid(Monoid(..))
import Graphics.UI.GLFW (Key(..))
import Graphics.UI.GLFW.Events (GLFWEvent(..), KeyEvent(..), IsPress(..))
import Graphics.UI.GLFW.ModState (ModState(..), noMods, shift, ctrl, alt)
import Prelude hiding (lookup)
import qualified Data.AtFieldTH as AtFieldTH
import qualified Data.Map as Map

data IsShifted = Shifted | NotShifted
  deriving (Eq, Ord, Show, Read)

data ModKey = ModKey ModState Key
  deriving (Show, Eq, Ord)

data EventType = KeyEventType IsPress ModKey
  deriving (Show, Eq, Ord)

charOfKey :: Key -> Maybe Char
charOfKey key =
  case key of
  CharKey c      -> Just c
  KeySpace       -> Just ' '
  KeyPad0        -> Just '0'
  KeyPad1        -> Just '1'
  KeyPad2        -> Just '2'
  KeyPad3        -> Just '3'
  KeyPad4        -> Just '4'
  KeyPad5        -> Just '5'
  KeyPad6        -> Just '6'
  KeyPad7        -> Just '7'
  KeyPad8        -> Just '8'
  KeyPad9        -> Just '9'
  KeyPadDivide   -> Just '/'
  KeyPadMultiply -> Just '*'
  KeyPadSubtract -> Just '-'
  KeyPadAdd      -> Just '+'
  KeyPadDecimal  -> Just '.'
  KeyPadEqual    -> Just '='
  _              -> Nothing

charKey :: Char -> Key
charKey = CharKey . toUpper

type Event = KeyEvent

type Doc = String

data EventHandler a = EventHandler {
  ehDoc :: Doc,
  ehHandler :: ModKey -> a
  } deriving (Functor)

-- CharHandlers always conflict with each other, but they may or may
-- not conflict with shifted/unshifted key events (but not with
-- alt'd/ctrl'd)
data CharHandler a = CharHandler
  { chInputDoc :: String
  , chDoc :: Doc
  , chHandler :: Char -> Maybe (IsShifted -> a)
  } deriving (Functor)
AtFieldTH.make ''CharHandler

data EventMap a = EventMap
  { emMap :: Map EventType (EventHandler a)
  , emCharHandler :: Maybe (CharHandler a)
  } deriving (Functor)
AtFieldTH.make ''EventMap

filterChars
  :: (Char -> Bool) -> EventMap a -> EventMap a
filterChars p =
  atEmCharHandler . fmap . atChHandler $
  \handler c -> if p c then handler c else Nothing

prettyKey :: Key -> String
prettyKey (CharKey x) = [toLower x]
prettyKey k
  | "Key" `isPrefixOf` show k = drop 3 $ show k
  | otherwise = show k

prettyModKey :: ModKey -> String
prettyModKey (ModKey ms key) = prettyModState ms ++ prettyKey key

prettyEventType :: EventType -> String
prettyEventType (KeyEventType Press modKey) = prettyModKey modKey
prettyEventType (KeyEventType Release modKey) =
  "Depress " ++ prettyModKey modKey

prettyModState :: ModState -> String
prettyModState ms = concat $
  ["Ctrl+" | modCtrl ms] ++
  ["Alt+" | modAlt ms] ++
  ["Shift+" | modShift ms]

isCharMods :: ModState -> Bool
isCharMods ModState { modCtrl = False, modAlt = False } = True
isCharMods _ = False

isShifted :: ModState -> IsShifted
isShifted ModState { modShift = True } = Shifted
isShifted ModState { modShift = False } = NotShifted

eventTypeOf :: IsPress -> ModKey -> Maybe Char -> EventType
eventTypeOf isPress (ModKey ms k) mchar =
  KeyEventType isPress . ModKey ms $
  if isCharMods ms && mchar == Just ' ' then KeySpace else k

instance Show (EventMap a) where
  show (EventMap m mc) =
    "EventMap (keys = " ++ show (Map.keys m) ++
    maybe "" showCharHandler mc ++ ")"
    where
      showCharHandler (CharHandler iDoc _ _) = ", handleChars " ++ iDoc

eventMapDocs :: EventMap a -> [(String, Doc)]
eventMapDocs (EventMap dict mCharHandler) =
  maybe [] ((:[]) . (chInputDoc &&& chDoc)) mCharHandler ++
  map (prettyEventType *** ehDoc) (Map.toList dict)

filterByKey :: Ord k => (k -> Bool) -> Map k v -> Map k v
filterByKey p = Map.filterWithKey (const . p)

overrides :: EventMap a -> EventMap a -> EventMap a
EventMap xMap xMCharHandler `overrides` EventMap yMap yMCharHandler =
  EventMap
  (xMap `mappend` filteredYMap)
  (xMCharHandler `mplus` yMCharHandler)
  where
    filteredYMap =
      maybe id (filterByKey . checkConflict) xMCharHandler yMap
    checkConflict charHandler (KeyEventType _ (ModKey mods key))
      | isCharMods mods =
        isNothing $
        chHandler charHandler =<< charOfKey key
      | otherwise = True

instance Monoid (EventMap a) where
  mempty = EventMap mempty Nothing
  mappend = overrides

delete :: EventType -> EventMap a -> EventMap a
delete = atEmMap . Map.delete

lookup :: Event -> EventMap a -> Maybe a
lookup (KeyEvent isPress ms mchar k) (EventMap dict mCharHandler) =
  lookupEvent `mplus` (lookupChar isPress =<< mCharHandler)
  where
    modKey = ModKey ms k
    lookupEvent =
      fmap (`ehHandler` modKey) $
      eventTypeOf isPress modKey mchar `Map.lookup` dict
    lookupChar Press (CharHandler _ _ handler)
      | isCharMods ms = fmap ($ isShifted ms) $ handler =<< mchar
      | otherwise = Nothing
    lookupChar _ _ = Nothing

-- low-level "smart constructor" in case we need to enforce
-- invariants:
charEventMap
  :: String -> Doc -> (Char -> Maybe (IsShifted -> a)) -> EventMap a
charEventMap = (fmap . fmap . fmap) (EventMap mempty . Just) CharHandler

allCharsEventMap
  :: String -> Doc -> (Char -> IsShifted -> a) -> EventMap a
allCharsEventMap iDoc oDoc f = charEventMap iDoc oDoc $ Just . f

simpleCharsEventMap
  :: String -> Doc -> (Char -> a) -> EventMap a
simpleCharsEventMap iDoc oDoc f =
  allCharsEventMap iDoc oDoc (const . f)

singleton :: EventType -> Doc -> (ModKey -> a) -> EventMap a
singleton eventType doc handler =
  flip EventMap Nothing . Map.singleton eventType $
  EventHandler {
    ehDoc = doc,
    ehHandler = handler
    }

keyPress :: ModKey -> Doc -> a -> EventMap a
keyPress modKey doc = singleton (KeyEventType Press modKey) doc . const

keyPresses :: [ModKey] -> Doc -> a -> EventMap a
keyPresses = mconcat . map keyPress
