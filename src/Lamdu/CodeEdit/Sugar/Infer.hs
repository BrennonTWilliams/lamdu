{-# LANGUAGE TemplateHaskell, DeriveFunctor #-}
module Lamdu.CodeEdit.Sugar.Infer
  ( Payload(..), plGuid, plInferred, plStored
  , NoInferred(..), InferredWC
  , NoStored(..), Stored

  , inferLoadedExpression
  , InferLoadedResult(..)
  , ilrSuccess, ilrContext, ilrInferContext
  , ilrExpr, ilrBaseExpr, ilrBaseInferContext

  , resultFromPure, resultFromInferred

  -- TODO: These don't belong here:
  -- Type-check an expression into an ordinary Inferred Expression,
  -- short-circuit on error:
  , inferMaybe, inferMaybe_
  ) where

import Control.Applicative ((<$>))
import Control.Arrow ((&&&))
import Control.Monad (void, (<=<))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT(..), evalStateT)
import Control.Monad.Trans.State.Utils (toStateT)
import Control.MonadA (MonadA)
import Data.Cache (Cache)
import Data.Hashable (hash)
import Data.Store.Guid (Guid)
import Data.Store.Transaction (Transaction)
import Lamdu.Data.IRef (DefI)
import Lamdu.Data.Infer.Conflicts (InferredWithConflicts(..), inferWithConflicts)
import System.Random (RandomGen)
import qualified Control.Lens as Lens
import qualified Control.Lens.TH as LensTH
import qualified Control.Monad.Trans.State as State
import qualified Data.Cache as Cache
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Data as Data
import qualified Lamdu.Data.IRef as DataIRef
import qualified Lamdu.Data.Infer as Infer
import qualified Lamdu.Data.Infer.ImplicitVariables as ImplicitVariables
import qualified Lamdu.Data.Load as Load
import qualified System.Random as Random
import qualified System.Random.Utils as RandomUtils

type T = Transaction
type CT m = StateT Cache (T m)

data NoInferred = NoInferred
type InferredWC = InferredWithConflicts DefI

data NoStored = NoStored
type Stored m = DataIRef.ExpressionProperty m

data Payload inferred stored
  = Payload
    { _plGuid :: Guid
    , _plInferred :: inferred
    , _plStored :: stored
    }
LensTH.makeLenses ''Payload

randomizeGuids ::
  RandomGen g => g -> (a -> inferred) ->
  Data.Expression DefI a ->
  Data.Expression DefI (Payload inferred NoStored)
randomizeGuids gen f =
    Data.randomizeParamIds paramGen
  . Data.randomizeExpr exprGen
  . fmap (toPayload . f)
  where
    toPayload inferred guid = Payload guid inferred NoStored
    paramGen : exprGen : _ = RandomUtils.splits gen

-- Not inferred, not stored
resultFromPure ::
  RandomGen g => g -> Data.Expression DefI () ->
  Data.Expression DefI (Payload NoInferred NoStored)
resultFromPure = (`randomizeGuids` const NoInferred)

resultFromInferred ::
  Data.Expression DefI (Infer.Inferred DefI) ->
  Data.Expression DefI (Payload InferredWC NoStored)
resultFromInferred expr =
  randomizeGuids gen f expr
  where
    gen = Random.mkStdGen . hash . show $ void expr
    f inferred =
      InferredWithConflicts
      { iwcInferred = inferred
      , iwcTypeConflicts = []
      , iwcValueConflicts = []
      }

-- {{{{{{{{{{{{{{{{{
-- TODO: These don't belong here
loader :: MonadA m => Infer.Loader DefI (T m)
loader =
  Infer.Loader
  (fmap void . DataIRef.readExpression . Lens.view Data.defType <=<
   Transaction.readIRef)

inferMaybe ::
  MonadA m =>
  Data.Expression DefI a -> Infer.Context DefI -> Infer.InferNode DefI ->
  T m (Maybe (Data.Expression DefI (Infer.Inferred DefI, a)))
inferMaybe expr inferContext inferPoint = do
  loaded <- Infer.load loader Nothing expr
  return . fmap fst . (`runStateT` inferContext) $
    Infer.inferLoaded (Infer.InferActions (const Nothing))
    loaded inferPoint

inferMaybe_ ::
  MonadA m =>
  Data.Expression DefI () -> Infer.Context DefI -> Infer.InferNode DefI ->
  T m (Maybe (Data.Expression DefI (Infer.Inferred DefI)))
inferMaybe_ expr inferContext inferPoint =
  (fmap . fmap . fmap) fst $ inferMaybe expr inferContext inferPoint
-- }}}}}}}}}}}}}}}}}

inferWithVariables ::
  (RandomGen g, MonadA m) => g ->
  Infer.Loaded DefI a -> Infer.Context DefI -> Infer.InferNode DefI ->
  T m
  ( ( Bool
    , Infer.Context DefI
    , Data.Expression DefI (InferredWithConflicts DefI, a)
    )
  , ( Infer.Context DefI
    , Data.Expression DefI (InferredWithConflicts DefI, ImplicitVariables.Payload a)
    )
  )
inferWithVariables gen loaded baseInferContext node =
  (`evalStateT` baseInferContext) $ do
    (success, expr) <- toStateT $ inferWithConflicts loaded node
    intermediateContext <- State.get
    wvExpr <-
      ImplicitVariables.addVariables gen loader $
      (iwcInferred . fst &&& id) <$> expr
    wvContext <- State.get
    return
      ( (success, intermediateContext, expr)
      , (wvContext, asIWC <$> wvExpr)
      )
  where
    asIWC (newInferred, ImplicitVariables.Stored (oldIWC, a)) =
      ( oldIWC { iwcInferred = newInferred }
      , ImplicitVariables.Stored a
      )
    asIWC (newInferred, ImplicitVariables.AutoGen guid) =
      ( InferredWithConflicts newInferred [] []
      , ImplicitVariables.AutoGen guid
      )

data InferLoadedResult m = InferLoadedResult
  { _ilrSuccess :: Bool
  , _ilrContext :: Infer.Loaded DefI Load.PropertyClosure
  , _ilrInferContext :: Infer.Context DefI
  , _ilrExpr :: Data.Expression DefI (Payload InferredWC (Maybe (Stored m)))
  -- Prior to adding variables
  , _ilrBaseInferContext :: Infer.Context DefI
  , _ilrBaseExpr :: Data.Expression DefI (Payload InferredWC (Stored m))
  }
LensTH.makeLenses ''InferLoadedResult

inferLoadedExpression ::
  (RandomGen g, MonadA m) => g ->
  Maybe DefI -> Load.LoadedClosure ->
  (Infer.Context DefI, Infer.InferNode DefI) ->
  CT m (InferLoadedResult (T m))
inferLoadedExpression gen mDefI lExpr inferState = do
  loaded <- lift $ Infer.load loader mDefI lExpr
  ((success, inferContext, expr), (wvInferContext, wvExpr)) <-
    Cache.memoS uncurriedInfer (loaded, inferState)
  return InferLoadedResult
    { _ilrSuccess = success
    , _ilrContext = loaded

    , _ilrBaseInferContext = inferContext
    , _ilrBaseExpr = mkStoredPayload <$> expr

    , _ilrInferContext = wvInferContext
    , _ilrExpr = mkWVPayload <$> wvExpr
    }
  where
    uncurriedInfer (loaded, (inferContext, inferNode)) =
      inferWithVariables gen loaded inferContext inferNode

    mkStoredPayload (iwc, propClosure) =
      Payload (DataIRef.epGuid prop) iwc prop
      where
        prop = Load.propertyOfClosure propClosure
    mkWVPayload (iwc, ImplicitVariables.AutoGen guid) =
      Payload guid iwc Nothing
    mkWVPayload (iwc, ImplicitVariables.Stored propClosure) =
      Lens.over plStored Just $
      mkStoredPayload (iwc, propClosure)