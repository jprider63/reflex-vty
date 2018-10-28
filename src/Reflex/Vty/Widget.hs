{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TypeFamilies #-}
module Reflex.Vty.Widget
  ( VtyWidgetCtx(..)
  , VtyWidget(..)
  , VtyWidgetOut(..)
  , runVtyWidget
  , mainWidget
  , mainWidgetWithHandle
  , HasDisplaySize(..)
  , displayWidth
  , displayHeight
  , HasFocus(..)
  , HasVtyInput(..)
  , Region(..)
  , regionSize
  , regionBlankImage
  , Drag (..)
  , drag
  , mouseDown
  , pane
  , modifyImages
  , tellImages
  , tellShutdown
  , wrapString
  , splitV
  , splitVDrag
  , fractionSz
  , box
  , string
  ) where

import Control.Applicative (liftA2)
import Control.Monad.Fix (MonadFix)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Reader (ReaderT, runReaderT, asks, ask)
import Control.Monad.Trans.Writer (WriterT, runWriterT, censor, tell)
import Graphics.Vty (Image, Attr)
import qualified Graphics.Vty as V 
import Reflex

import Reflex.Vty.Host

-- | The context within which a 'VtyWidget' runs
data VtyWidgetCtx t = VtyWidgetCtx
  { _vtyWidgetCtx_size :: Dynamic t (Int,Int)
    -- ^ The width and height of the region allocated to the widget.
  , _vtyWidgetCtx_focus :: Dynamic t Bool
    -- ^ Whether the widget should behave as if it has focus for keyboard input.
  , _vtyWidgetCtx_input :: Event t VtyEvent
    -- ^ User input events that the widget's parent chooses to share. These will generally
    -- be filtered for relevance: 
    --  * Keyboard inputs are restricted to focused widgets
    --  * Mouse inputs are restricted to the region in which the widget resides and are
    --  translated into its internal coordinates.
  }

-- | The output of a 'VtyWidget'
data VtyWidgetOut t = VtyWidgetOut
  { _vtyWidgetOut_images :: Behavior t [Image]
    -- ^ The visual output of the 'VtyWidget'
  , _vtyWidgetOut_shutdown :: Event t ()
  }

instance Reflex t => Semigroup (VtyWidgetOut t) where
  wo <> wo' = VtyWidgetOut
    { _vtyWidgetOut_images = _vtyWidgetOut_images wo <> _vtyWidgetOut_images wo'
    , _vtyWidgetOut_shutdown = _vtyWidgetOut_shutdown wo <> _vtyWidgetOut_shutdown wo'
    }

instance (Reflex t) => Monoid (VtyWidgetOut t) where
  mempty = VtyWidgetOut mempty mempty
  mappend wo wo' = wo <> wo'

newtype VtyWidget t m a = VtyWidget { unVtyWidget :: WriterT (VtyWidgetOut t) (ReaderT (VtyWidgetCtx t) m) a }
  deriving (Functor, Applicative, Monad, MonadSample t, MonadHold t, MonadFix)

-- | Runs a 'VtyWidget' with a given context
runVtyWidget :: (Reflex t)
  => VtyWidgetCtx t
  -> VtyWidget t m a
  -> m (a, VtyWidgetOut t)
runVtyWidget ctx w = runReaderT (runWriterT (unVtyWidget w)) ctx

-- | Sets up the top-level context for a 'VtyWidget' and runs it with that context
mainWidgetWithHandle :: V.Vty -> (forall t m. MonadVtyApp t m => VtyWidget t m ()) -> IO ()
mainWidgetWithHandle vty child =
  runVtyAppWithHandle vty $ \dr0 inp -> do
    size <- holdDyn dr0 $ fforMaybe inp $ \case
      V.EvResize w h -> Just (w, h)
      _ -> Nothing
    let ctx = VtyWidgetCtx
          { _vtyWidgetCtx_size = size
          , _vtyWidgetCtx_input = inp
          , _vtyWidgetCtx_focus = constDyn True
          }
    ((), wo) <- runVtyWidget ctx child
    return $ VtyResult
      { _vtyResult_picture = fmap (V.picForLayers . reverse) (_vtyWidgetOut_images wo)
      , _vtyResult_shutdown = _vtyWidgetOut_shutdown wo
      }

-- | Like 'mainWidgetWithHandle', but uses a default vty configuration
mainWidget :: (forall t m. MonadVtyApp t m => VtyWidget t m ()) -> IO ()
mainWidget child = do
  vty <- getDefaultVty
  mainWidgetWithHandle vty child

class (Reflex t, Monad m) => HasDisplaySize t m | m -> t where
  displaySize :: m (Dynamic t (Int, Int))

instance (Reflex t, Monad m) => HasDisplaySize t (VtyWidget t m) where
  displaySize = VtyWidget . lift $ asks _vtyWidgetCtx_size

displayWidth :: HasDisplaySize t m => m (Dynamic t Int)
displayWidth = fmap fst <$> displaySize

displayHeight :: HasDisplaySize t m => m (Dynamic t Int)
displayHeight = fmap snd <$> displaySize

class HasVtyInput t m | m -> t where
  input :: m (Event t VtyEvent)

instance (Reflex t, Monad m) => HasVtyInput t (VtyWidget t m) where
  input = VtyWidget . lift $ asks _vtyWidgetCtx_input

class HasFocus t m | m -> t where
  focus :: m (Dynamic t Bool)

instance (Reflex t, Monad m) => HasFocus t (VtyWidget t m) where
  focus = VtyWidget . lift $ asks _vtyWidgetCtx_focus

class (Reflex t, Monad m) => ImageWriter t m | m -> t where
  tellImages :: Behavior t [Image] -> m ()

instance (Reflex t, Monad m) => ImageWriter t (VtyWidget t m) where
  tellImages imgs = VtyWidget $ tell (mempty { _vtyWidgetOut_images = imgs })

class (Reflex t, Monad m) => Shutdown t m where
  tellShutdown :: Event t () -> m ()

instance (Reflex t, Monad m) => Shutdown t (VtyWidget t m) where
  tellShutdown sd = VtyWidget $ tell (mempty { _vtyWidgetOut_shutdown = sd })

data Region = Region
  { _region_left :: Int
  , _region_top :: Int
  , _region_width :: Int
  , _region_height :: Int
  }
  deriving (Show, Read, Eq, Ord)

regionSize :: Region -> (Int, Int)
regionSize (Region _ _ w h) = (w, h)

pane
  :: (Reflex t, Monad m)
  => Dynamic t Region -- ^ Region into which we should draw the widget (in coordinates relative to our own)
  -> Dynamic t Bool -- ^ Whether the widget should be focused when the parent is.
  -> VtyWidget t m a
  -> VtyWidget t m a
pane reg foc child = VtyWidget $ do
  ctx <- lift ask
  let ctx' = VtyWidgetCtx
        { _vtyWidgetCtx_input = leftmost -- TODO: think about this leftmost more.
            [ ffor (updated reg) $ \(Region _ _ w h) -> V.EvResize w h
            , fmapMaybe id $
                attachWith (\(r,f) e -> filterInput r f e)
                  (liftA2 (,) (current reg) (current foc))
                  (_vtyWidgetCtx_input ctx)
            ]
        , _vtyWidgetCtx_focus = liftA2 (&&) (_vtyWidgetCtx_focus ctx) foc
        , _vtyWidgetCtx_size = fmap regionSize reg }
  (result, wo) <- lift . lift $ runVtyWidget ctx' child
  let images = _vtyWidgetOut_images wo
      images' = liftA2 (\r is -> map (withinImage r) is) (current reg) images
      wo' = wo { _vtyWidgetOut_images = images' }
  tell wo'
  return result
  where
    -- Filters input such that:
    -- * unfocused widgets receive no key events
    -- * mouse inputs outside the region are ignored
    -- * mouse inputs inside the region have their coordinates translated
    -- such that (0,0) is the top-left corner of the region
    filterInput :: Region -> Bool -> VtyEvent -> Maybe VtyEvent
    filterInput (Region l t w h) focused e = case e of
      V.EvKey _ _ | not focused -> Nothing
      V.EvMouseDown x y btn m -> mouse (\u v -> V.EvMouseDown u v btn m) x y
      V.EvMouseUp x y btn -> mouse (\u v -> V.EvMouseUp u v btn) x y
      _ -> Just e
      where
        mouse con x y
          | or [ x < l
               , y < t
               , x >= l + w
               , y >= t + h ] = Nothing
          | otherwise =
            Just (con (x - l) (y - t))

data Drag = Drag
  { _drag_from :: (Int, Int) -- ^ Where the drag began
  , _drag_to :: (Int, Int) -- ^ Where the mouse currently is
  , _drag_button :: V.Button -- ^ Which mouse button is dragging
  , _drag_modifiers :: [V.Modifier] -- ^ What modifiers are held
  , _drag_end :: Bool -- ^ Whether the drag ended (the mouse button was released)
  }
  deriving (Eq, Ord, Show)

drag
  :: (Reflex t, MonadFix m, MonadHold t m)
  => V.Button
  -> VtyWidget t m (Event t Drag)
drag btn = do
  inp <- input
  let f :: Drag -> V.Event -> Maybe Drag
      f (Drag from _ _ mods end) = \case
        V.EvMouseDown x y btn' mods'
          | end         -> Just $ Drag (x,y) (x,y) btn' mods' False
          | btn == btn' -> Just $ Drag from (x,y) btn mods' False
          | otherwise   -> Nothing -- Ignore other buttons.
        V.EvMouseUp x y (Just btn')
          | end         -> Nothing
          | btn == btn' -> Just $ Drag from (x,y) btn mods True
          | otherwise   -> Nothing
        V.EvMouseUp x y Nothing -- Terminal doesn't specify mouse up button,
                                -- assume it's the right one.
          | end       -> Nothing
          | otherwise -> Just $ Drag from (x,y) btn mods True
        _ -> Nothing
  rec let newDrag = attachWithMaybe f (current dragD) inp
      dragD <- holdDyn (Drag (0,0) (0,0) V.BLeft [] True) -- gross, but ok.
                       newDrag
  return (updated dragD)

mouseDown
  :: (Reflex t, Monad m)
  => V.Button
  -> VtyWidget t m (Event t VtyEvent)
mouseDown btn = do
  i <- input
  return $ fforMaybe i $ \x -> case x of
    V.EvMouseDown _ _ btn' _ -> if btn == btn' then Just x else Nothing
    _ -> Nothing

-- | A plain split of the available space into vertically stacked panes.
-- No visual separator is built in here.
splitV :: (Reflex t, Monad m)
       => Dynamic t (Int -> Int)
       -- ^ Function used to determine size of first pane based on available size
       -> Dynamic t (Bool, Bool)
       -- ^ How to focus the two sub-panes, given that we are focused.
       -> VtyWidget t m a
       -- ^ Widget for first pane
       -> VtyWidget t m b
       -- ^ Widget for second pane
       -> VtyWidget t m (a,b)
splitV sizeFunD focD wA wB = do
  sz <- displaySize
  let regA = (\f (w,h) -> Region 0 0 w (f h)) <$> sizeFunD <*> sz
      regB = (\(w,h) (Region _ _ _ hA) -> Region 0 hA w (h - hA)) <$> sz <*> regA
  ra <- pane regA (fst <$> focD) wA
  rb <- pane regB (snd <$> focD) wB
  return (ra,rb)

-- | A split of the available space into two parts with a draggable separator.
-- Starts with half the space allocated to each, and the first pane has focus.
-- Clicking in a pane switches focus.
splitVDrag :: (Reflex t, MonadFix m, MonadHold t m)
  => VtyWidget t m a
  -> VtyWidget t m b
  -> VtyWidget t m (a,b)
splitVDrag wA wB = do
  sz <- displaySize
  (_, h0) <- sample $ current sz
  dragE <- drag V.BLeft
  let splitter0 = h0 `div` 2
  rec splitterCheckpoint <- holdDyn splitter0 $ fst <$> ffilter snd dragSplitter
      splitterPos <- holdDyn splitter0 $ fst <$> dragSplitter
      let dragSplitter = fforMaybe (attach (current splitterCheckpoint) dragE) $ \(splitterY, Drag (_, fromY) (_, toY) _ _ end) ->
            if splitterY == fromY then Just (toY, end) else Nothing
          regA = (\(w,_) sp -> Region 0 0 w sp) <$> sz <*> splitterPos
          regS = (\(w,_) sp -> Region 0 sp w 1) <$> sz <*> splitterPos
          regB = (\(w,h) sp -> Region 0 (sp + 1) w (h - sp - 1)) <$> sz <*> splitterPos
      focA <- holdDyn True $ leftmost
        [ True <$ mA
        , False <$ mB
        ]
      (mA, rA) <- pane regA focA $ withMouseDown wA
      tellImages $ ffor (current regS) $ \r -> [withinImage r (V.string mempty (replicate (_region_width r) '='))]
      (mB, rB) <- pane regB (not <$> focA) $ withMouseDown wB
  return (rA, rB)
  where
    withMouseDown x = do
      m <- mouseDown V.BLeft
      x' <- x
      return (m, x')

fractionSz :: Double -> Int -> Int
fractionSz x h = round (fromIntegral h * x)

modifyImages
  :: (Reflex t, MonadHold t m, MonadFix m)
  => Behavior t ([Image] -> [Image])
  -> VtyWidget t m a
  -> VtyWidget t m a
modifyImages f (VtyWidget w) = VtyWidget $ flip censor w $ \wo -> 
  wo { _vtyWidgetOut_images = f <*> (_vtyWidgetOut_images wo) }

box :: (Monad m, Reflex t)
    => VtyWidget t m a
    -> VtyWidget t m a
box child = do
  sz <- displaySize
  let boxReg = ffor (current sz) $ \(w,h) -> Region 0 0 w h
      innerReg = ffor sz $ \(w,h) -> Region 1 1 (w - 2) (h - 2)
  tellImages (fmap boxImages boxReg)
  tellImages (fmap (\r -> [regionBlankImage r]) (current innerReg))
  pane innerReg (pure True) child
  where
    boxImages :: Region -> [Image]
    boxImages r@(Region left top width height) =
      let hBorder = V.string mempty $ replicate width '-'
          vBorder = wrapString 1 mempty $ replicate (height - 2) '|'
      in  [ withinImage (r { _region_height = 1 }) hBorder
          , withinImage (Region left (top + 1) 1 (height - 2)) vBorder
          , withinImage (Region (left + width - 1) (top + 1) 1 (height - 2)) vBorder
          , withinImage (r { _region_top = top + height - 1 }) hBorder
          ]

string :: (Reflex t, Monad m) => Behavior t String -> VtyWidget t m ()  
string msg = do
  dw <- displayWidth
  let img = (\w s -> [wrapString w mempty s]) <$> current dw <*> msg
  tellImages img

regionBlankImage :: Region -> Image
regionBlankImage r@(Region _ _ width height) =
  withinImage r $ wrapString width V.defAttr $ replicate (width * height) ' '

withinImage :: Region -> Image -> Image
withinImage (Region left top width height)
  | width < 0 || height < 0 = withinImage (Region left top 0 0)
  | otherwise = V.translate left top . V.crop width height

wrapString :: Int -> Attr -> String -> Image
wrapString maxWidth attrs = V.vertCat . concatMap (fmap (V.string attrs) . fmap (take maxWidth) . takeWhile (not . null) . iterate (drop maxWidth)) . lines
