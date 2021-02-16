{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Futhark.AD.Rev (revVJP) where

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Bifunctor (second)
import Data.List (sortOn, (\\))
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S
import Debug.Trace
import Futhark.AD.Derivatives
import Futhark.Analysis.PrimExp.Convert
import Futhark.Binder
import Futhark.Construct
import Futhark.IR.SOACS
import Futhark.Transform.Rename
import Futhark.Transform.Substitute

data Env = Env
  { adjs :: M.Map VName VName,
    tape :: M.Map VName VName,
    vns :: VNameSource
  }

data REnv = REnv
  { tans :: M.Map VName VName,
    envScope :: Scope SOACS
  }

newtype ADM a = ADM (ReaderT REnv (State Env) a)
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadReader REnv,
      MonadState Env,
      MonadFreshNames
    )

instance MonadFreshNames (State Env) where
  getNameSource = gets vns
  putNameSource vns' = modify (\env -> env {vns = vns'})

instance HasScope SOACS ADM where
  askScope = asks envScope

instance LocalScope SOACS ADM where
  localScope scope = local $ \env -> env {envScope = scope <> envScope env}

runADM :: MonadFreshNames m => ADM a -> REnv -> m a
runADM (ADM m) renv =
  modifyNameSource $ \vn -> second vns $ runState (runReaderT m renv) (Env mempty mempty vn)

adjVName :: VName -> ADM VName
adjVName v = newVName (baseString v <> "_adj")

newAdj :: VName -> ADM (VName, M.Map VName VName, Stms SOACS)
newAdj v = do
  v_adj <- adjVName v
  t <- lookupType v
  let update = M.singleton v v_adj
  modify $ \env -> env {adjs = update `M.union` adjs env}
  -- Cosmin commented/changed since does not zero out arrays!
  stms <- runBinder_ $ letBindNames [v_adj] =<< eBlank t
  return (v_adj, update, stms)

accVName :: VName -> ADM VName
accVName v = newVName (baseString v <> "_acc")

insTape :: VName -> VName -> ADM ()
insTape v acc = modify $ \env -> env {tape = M.insert v acc (tape env)}

insAdj :: VName -> VName -> ADM ()
insAdj v _v = modify $ \env -> env {adjs = M.insert v _v (adjs env)}

insAdjMap :: M.Map VName VName -> ADM ()
insAdjMap update = modify $ \env -> env {adjs = update `M.union` adjs env}

lookupTape :: VName -> ADM (Maybe VName)
lookupTape v = gets $ M.lookup v . tape

class Adjoint a where
  lookupAdj :: a -> ADM (VName, M.Map VName VName, Stms SOACS)
  updateAdjoint :: a -> VName -> ADM (VName, M.Map VName VName, Stms SOACS)
  updateAdjointArray :: Maybe (Slice SubExp) -> a -> VName -> ADM (VName, M.Map VName VName, Stms SOACS)

addBinOp :: PrimType -> BinOp
addBinOp (IntType it) = Add it OverflowWrap
addBinOp (FloatType ft) = FAdd ft
addBinOp Bool = LogAnd
addBinOp Cert = LogAnd

instance Adjoint VName where
  lookupAdj v = do
    maybeAdj <- gets $ M.lookup v . adjs
    case maybeAdj of
      Nothing -> newAdj v
      Just v_adj -> return (v_adj, mempty, mempty)

  updateAdjoint v d = do
    maybeAdj <- gets $ M.lookup v . adjs
    case maybeAdj of
      Nothing -> setAdjoint v (BasicOp . SubExp . Var $ d)
      Just _v -> do
        t <- lookupType v
        (_v', stms) <- runBinder . letExp "adj" $
          case t of
            Prim pt ->
              BasicOp $ BinOp (addBinOp pt) (Var _v) (Var d)
            _ ->
              error $ "updateAdjoint: unexpected type " <> pretty t
        let update = M.singleton v _v'
        insAdjMap update
        return (_v', update, stms)

  updateAdjointArray maybe_slice v d = do
    maybeAdj <- gets $ M.lookup v . adjs
    t <- lookupType v
    case maybeAdj of
      Nothing -> do
        (_v, us1, s1) <- lookupAdj v
        (_v', us2, s2) <- updateAdjointArray maybe_slice v d
        return (_v', us2 <> us1, s1 <> s2)
      Just _v -> do
        (_v', stms) <- inScopeOf (_v, LParamName t) $
          runBinderT' $
            case maybe_slice of
              Nothing -> do
                t' <- lookupType _v
                letExp "updated_adj" =<< addArrays t' _v d
              Just slice -> do
                _vslice <-
                  if primType t
                    then return _v
                    else letExp (baseString _v ++ "_slice") $ BasicOp $ Index _v slice
                t' <- lookupType _vslice
                _vslice' <- addArrays t' _vslice d
                letInPlace "updated_adj" _v slice _vslice'
        let us = M.singleton v _v'
        insAdjMap us
        return (_v', us, stms)
    where
      addArrays t xs ys =
        case elemType t of
          ElemAcc {} ->
            error $ "addArrays: " ++ pretty t
          ElemPrim pt ->
            case (shapeDims . arrayShape) t of
              [] -> return $ BasicOp $ BinOp (addBinOp pt) (Var xs) (Var ys)
              (s : ss) -> do
                lam <- addArrays' $ t `setArrayShape` Shape ss
                return $ Op $ Screma s (mapSOAC lam) [xs, ys]

      addArrays' t =
        case (elemType t, shapeDims $ arrayShape t) of
          (ElemAcc {}, _) -> error $ "addArrays': " ++ pretty t
          (ElemPrim pt, []) -> binOpLambda (addBinOp pt) pt
          (_, s : ss) -> do
            xs <- newVName "xs"
            ys <- newVName "ys"
            let t' = t `setArrayShape` Shape ss
            lam <- addArrays' t'
            body <- insertStmsM $ do
              res <- letSubExp "lam_map" $ Op $ Screma s (mapSOAC lam) [xs, ys]
              return $ resultBody [res]
            return
              Lambda
                { lambdaParams = [Param xs t', Param ys t'],
                  lambdaReturnType = [t'],
                  lambdaBody = body
                }

instance Adjoint SubExp where
  lookupAdj (Constant c) = do
    (_v, stms) <- runBinderT' $ letExp "const_adj" =<< eBlank (Prim $ primValueType c)
    return (_v, mempty, stms)
  lookupAdj (Var v) = lookupAdj v

  updateAdjoint se@Constant {} _ = lookupAdj se
  updateAdjoint (Var v) d = updateAdjoint v d

  updateAdjointArray _ se@Constant {} _ = lookupAdj se
  updateAdjointArray maybe_slice (Var v) d = updateAdjointArray maybe_slice v d

localS :: MonadState s m => (s -> s) -> m a -> m a
localS f m = do
  save <- get
  modify f
  a <- m
  put save
  return a

eIndex :: MonadBinder m => VName -> SubExp -> m (ExpT (Lore m))
eIndex arr i =
  return . BasicOp . Index arr . pure $ DimFix i

setAdjoint :: VName -> Exp -> ADM (VName, M.Map VName VName, Stms SOACS)
setAdjoint v e = do
  _v <- adjVName v
  stms <- runBinderT'_ $ letBindNames [_v] e
  let update = M.singleton v _v
  insAdjMap update
  return (_v, update, stms)

revFwdStm :: Stm -> ADM (Stms SOACS)
revFwdStm (Let (Pattern [] pats) aux (DoLoop [] valpats (ForLoop v it bound []) (Body () stms res))) = do
  accs <- mapM (accVName . patElemName) pats
  accsLoop <- mapM (accVName . paramName . fst) valpats

  runBinderT'_ $ do
    let accTs = map (accType bound NoUniqueness . patElemDec) pats
        accTsLoop = map (accType bound Unique . paramDec . fst) valpats
        accPats = zipWith PatElem accs accTs
    emptyAccs <- forM (zip3 accsLoop accTsLoop accTs) $ \(accLoop, accTLoop, accT) -> do
      blankV <- letSubExp "empty_acc" =<< eBlank accT
      return (Param accLoop accTLoop, blankV)
    (accsLoop', loop_body_stms) <- runBinderT' $ do
      accsLoop' <- forM (zip3 accsLoop accTs valpats) $ \(accLoop, accT, (param, _)) ->
        inScopeOf (accLoop, LParamName accT) $ do
          arr_t <- lookupType accLoop
          is' <- mapM (letSubExp "write_i") =<< sequence [toExp v]
          v' <- letSubExp "write_v" =<< toExp (paramName param)
          fmap Var $
            letInPlace
              "update_acc"
              accLoop
              (fullSlice arr_t (map DimFix is'))
              $ BasicOp $ SubExp v'
      addStms stms
      return accsLoop'
    let body' = Body () loop_body_stms $ res ++ accsLoop'
    addStm $
      Let (Pattern [] (pats ++ accPats)) aux $
        DoLoop [] (valpats ++ emptyAccs) (ForLoop v it bound []) body'
    lift $ zipWithM_ (insTape . patElemName) pats accs
  where
    accType n u (Prim t) = Array (ElemPrim t) (Shape [n]) u
    accType n _ (Array t (Shape dims) u) = Array t (Shape (n : dims)) u
    accType _ _ Acc {} = error "Accumulator encountered."
    accType _ _ Mem {} = error "Mem type encountered."
revFwdStm stm = return $ oneStm stm

revStm :: Stm -> ADM (M.Map VName VName, Stms SOACS)
revStm stm@(Let (Pattern [] pats) aux (DoLoop [] valpats (ForLoop v it bound []) (Body () stms_ res_))) =
  --fwdStm <- revFwdStm stm
  inScopeOf stm $
    localScope (scopeOfFParams $ map fst valpats ++ [Param v (Prim (IntType it))]) $ do
      -- Populate the body with a filler statement if there are none (makes taking adjoints easier).
      body@(Body () stms res) <-
        if stms_ == mempty
          then do
            (res', stms) <-
              runBinderT' $
                mapM (letSubExp "filler" . BasicOp . SubExp) res_
            return $ Body () stms res'
          else return $ Body () stms_ res_

      -- Get the adjoints of the iteration variables.
      let iter_vars = map (paramName . fst) valpats
      (_iter_vars, _iter_map, iter_stms) <- unzip3 <$> mapM lookupAdj iter_vars

      -- "Reset" expressions for the iteration adjoints. Reset
      -- expressions just zero-out the adjoint so that the adjoint on
      -- each loop iteration starts from 0. (If you unroll a loop,
      -- each iteration adjoint would be unique and thus start from
      -- 0.)
      (_iter_reset, _iter_reset_stms) <-
        runBinderT' $
          mapM (letExp "reset" <=< eBlank <=< lookupType) iter_vars

      -- Construct param-value bindings for the iteration adjoints.
      _iter_params <- inScopeOf (_iter_reset_stms : iter_stms) $ mkBindings _iter_vars _iter_reset

      -- Get adjoints for the free variables in the loop. Iteration
      -- variables are free in the body but bound by the loop, which
      -- is why they're subtracted off.
      let fv = namesToList (freeIn body) \\ iter_vars

      -- Get the adjoints of the result variables
      (_free_vars, _free_map, free_stms) <- unzip3 <$> mapM lookupAdj fv

      -- Generate new names to bind `_free_vars` to `valpats` and
      -- link them to the free variables.
      _free_binds <- forM _free_vars $ newVName . baseString
      zipWithM_ insAdj fv _free_binds

      -- Construct param-value bindings the free variable adjoints.
      _free_params <- inScopeOf free_stms $ mkBindings _free_binds _free_vars

      -- Make adjoints for each result variable of the original body.
      -- The result adjoints of the ith iteration must be set to the
      -- adjoints of the saved loop variables of the i+1th iteration.
      -- Important: this must be done *before* computing the
      -- reverse of the body.
      _original_res <- forM (subExpVars res) $ \res_v -> do
        res_v' <- adjVName res_v
        insAdj res_v res_v'
        return res_v'

      -- return (Param _b (toDecl t Unique), Var _v)
      -- Compute the reverse of the body.
      (body_update_map, Body () _stms _res) <-
        localScope (scopeOfFParams $ map fst $ _free_params ++ _iter_params) $
          revBody' body

      (_body_res_vars, _body_res_map, body_res_stms) <- unzip3 <$> mapM lookupAdj (subExpVars res)

      zipWithM_ insAdj fv _free_binds

      let body_update_map_free = M.restrictKeys body_update_map $ S.fromList fv

      (_iter_vars', _, _) <- unzip3 <$> mapM lookupAdj iter_vars
      let _res' = map Var $ _iter_reset ++ _iter_vars' ++ M.elems body_update_map_free

      -- Remove any free paramters that weren't actually updated in the loop body
      let _free_params' = map fst $ filter ((`M.member` body_update_map_free) . snd) $ zip _free_params fv

      -- Construct the new return patterns.
      _pats_iter <- inScopeOf (mconcat iter_stms) $ mkPats _iter_vars
      _pats_body_res <- inScopeOf stms $ mkPats' (subExpVars res) _body_res_vars
      _pats_free_vars <- inScopeOf _stms $ mkPats $ M.elems body_update_map_free

      let _pats = _pats_iter ++ _pats_body_res ++ _pats_free_vars

      -- Construct value bindings for the body result adjoints. The initial binding is simply the
      -- adjoint of the nth iteration, which is given by the variables in the original pattern of the let-bind.
      (_loopres, _loopres_map, loopres_stms) <- unzip3 <$> forM pats (\(PatElem p _) -> lookupAdj p)

      let _body_params =
            zipWith3
              (\_b (PatElem _ t) _l -> (Param _b (toDecl t Unique), Var _l))
              _original_res
              _pats_body_res
              _loopres

      (bound', boundStms) <-
        runBinderT' $
          letSubExp "bound" $
            BasicOp (BinOp (Sub it OverflowWrap) bound (Constant $ IntValue $ intValue it (1 :: Int)))

      -- Look-up the stored loop iteration variables. Iteration
      -- variables are the variables bound in `valpats`. Every
      -- iteration of the loop, they are rebound to the result of the
      -- loop body.
      saved_iter_vars_maybe <- sequence <$> mapM (lookupTape . patElemName) pats

      (saved_iter_vars, fwdStms) <- case saved_iter_vars_maybe of
        Just saved_iter_vars -> return (saved_iter_vars, mempty)
        Nothing -> do
          fwdStms <- revFwdStm stm
          saved_iter_vars <- sequence <$> mapM (lookupTape . patElemName) pats
          case saved_iter_vars of
            Just saved_iter_vars' -> return (saved_iter_vars', fwdStms)
            Nothing -> error "oops"

      inScopeOf fwdStms $ do
        -- Loop body set-up
        (v', _loopSetup) <- runBinderT' $ do
          -- Go backwards
          v' <- letSubExp "idx" $ BasicOp (BinOp (Sub it OverflowWrap) bound' (Var v))

          -- Bind the accumulators
          forM_ (zip saved_iter_vars valpats) $ \(iter_var, (param, _)) ->
            letBindNames [paramName param] =<< eIndex iter_var v'

          return v'

        let subst = case v' of Constant {} -> error "oops"; Var v'' -> M.singleton v v''
            _valpats = _iter_params ++ _body_params ++ _free_params'
            _body = Body () (_loopSetup <> substituteNames subst _stms) _res'
            _stm = Let (Pattern [] _pats) aux (DoLoop [] _valpats (ForLoop v it bound []) _body)

        -- Update the free variables to point to new correct adjoints
        zipWithM_ insAdj fv $ map patElemName _pats_free_vars

        -- If any free variables weren't updated, fix their adjoint bindings
        mapM_ (uncurry insAdj) $
          filter ((`notElem` M.keys body_update_map_free) . fst) $
            zip fv _free_vars

        (_, _, final_contrib_stms) <-
          inScopeOf _stm $
            unzip3
              <$> mapM
                (uncurry updateAdjoint)
                ( mapMaybe
                    ( \(se, p) -> case se of
                        Var se_v -> Just (se_v, p)
                        _ -> Nothing
                    )
                    $ zip (map snd valpats) (map patElemName _pats_body_res)
                )

        adj_map <- gets adjs

        let changed_fv_map = M.restrictKeys adj_map $ S.fromList (fv ++ namesToList (freeIn (map snd valpats)))

        return (changed_fv_map, fwdStms <> boundStms <> _iter_reset_stms <> mconcat free_stms <> mconcat loopres_stms <> oneStm _stm <> mconcat final_contrib_stms)
  where
    mkBindings =
      zipWithM $ \_b _v -> do
        t <- lookupType _v
        return (Param _b (toDecl t Unique), Var _v)
    mkPats = mapM $ \_v -> do
      t <- lookupType _v
      _p <- newVName $ baseString _v <> "_res"
      return $ PatElem _p t

    mkPats' = zipWithM $ \resv _resv -> do
      t <- lookupType resv
      _p <- newVName $ baseString _resv <> "_res"
      return $ PatElem _p t
revStm stm@(Let _ _ (BasicOp CmpOp {})) =
  return (mempty, oneStm stm)
revStm stm@(Let (Pattern [] [pe]) _aux (BasicOp (UnOp op x))) = do
  let t = unOpType op
  (pe_adj, us1, s1) <- inScopeOf stm $ lookupAdj $ patElemName pe
  (contrib, contrib_stms) <- runBinder $ do
    let x_pe = primExpFromSubExp t x
        pe_adj' = primExpFromSubExp t (Var pe_adj)
        dx = pdUnOp op x_pe
    letExp "contrib" <=< toExp $ pe_adj' ~*~ dx

  (_, us2, s2) <- inScopeOf contrib_stms $ updateAdjoint x contrib

  pure
    ( us2 <> us1,
      s1 <> contrib_stms <> s2
    )
revStm stm@(Let (Pattern [] [pe]) _aux (BasicOp (BinOp op x y))) = do
  let t = binOpType op
  (_p, us1, s1) <- inScopeOf stm $ lookupAdj $ patElemName pe
  (_x, us2, s2) <- lookupAdj x
  (_y, us3, s3) <- lookupAdj y

  let (wrt_x, wrt_y) =
        pdBinOp op (primExpFromSubExp t x) (primExpFromSubExp t y)

      _p' = primExpFromSubExp t $ Var _p

  (adj_x, adj_x_s) <- runBinder $ letExp "adj" <=< toExp $ _p' ~*~ wrt_x
  (adj_y, adj_y_s) <- runBinder $ letExp "adj" <=< toExp $ _p' ~*~ wrt_y
  (_, x_us, x_s) <- updateAdjoint x adj_x
  (_, y_us, y_s) <- updateAdjoint y adj_y

  pure
    ( y_us <> x_us <> us3 <> us2 <> us1,
      s1 <> s2 <> s3 <> adj_x_s <> adj_y_s <> x_s <> y_s
    )
revStm stm@(Let (Pattern [] pats) aux (If cond t@(Body _ t_stms t_res) f@(Body _ f_stms f_res) attr)) = do
  (_pats, uspats, stm_pats) <- unzip3 <$> mapM (lookupAdj . patElemName) pats
  fwdStms <- revFwdStm stm
  t_fwd <- revFwdStms t_stms
  f_fwd <- revFwdStms f_stms
  zipWithM_ insAdj (subExpVars t_res) _pats
  zipWithM_ insAdj (subExpVars f_res) _pats
  saved_adjs <- gets adjs
  (t_map, _, _t@(Body t_desc t_stms_rev _t_res)) <- revBody t
  modify $ \env -> env {adjs = saved_adjs}
  (f_map, _, _f@(Body f_desc f_stms_rev _f_res)) <- revBody f
  modify $ \env -> env {adjs = saved_adjs}

  let deltas = sortOn baseTag $ M.keys $ t_map `M.union` f_map

  (_deltas, _, delta_stms) <- unzip3 <$> mapM lookupAdj deltas

  _t_res' <- localS (\env -> env {adjs = t_map `M.union` adjs env}) $ do
    (_t_res', _, _) <- unzip3 <$> mapM lookupAdj deltas
    return _t_res'

  _f_res' <- localS (\env -> env {adjs = f_map `M.union` adjs env}) $ do
    (_f_res', _, _) <- unzip3 <$> mapM lookupAdj deltas
    return _f_res'

  (_pats', res_map) <-
    unzip
      <$> forM
        deltas
        ( \v -> do
            v_t <- lookupType v
            v' <- adjVName v
            insAdj v v'
            return (PatElem v' v_t, M.singleton v v')
        )

  let _t' = Body t_desc (t_fwd <> t_stms_rev) $ map Var _t_res'
      _f' = Body f_desc (f_fwd <> f_stms_rev) $ map Var _f_res'

  ifret <- staticShapes <$> forM deltas lookupType
  let attr' = attr {ifReturns = ifret}

  return (mconcat res_map, fwdStms <> mconcat delta_stms <> oneStm (Let (Pattern [] _pats') aux (If cond _t' _f' attr')))
revStm (Let (Pattern [] [pat@(PatElem p t)]) _ (BasicOp (Index v slice))) = do
  (_p, us1, s1) <- inScopeOf (p, LParamName t) $ lookupAdj $ patElemName pat
  (_, us2, s2) <- updateAdjointArray (Just slice) v _p
  return (us2 <> us1, s1 <> s2)
revStm (Let (Pattern [] [pe]) _ (BasicOp (SubExp se)))
  | Var v <- se = do
    (_p, us1, s1) <- localScope (scopeOfPatElem pe) $ lookupAdj $ patElemName pe
    (_, us2, s2) <- updateAdjoint v _p
    return (us2 <> us1, s1 <> s2)
  | otherwise = return (mempty, mempty)
revStm (Let (Pattern [] [_]) _ (BasicOp (Reshape change v))) = do
  -- FIXME: how it be right to ignore the pattern?
  maybeAdj <- gets $ M.lookup v . adjs
  case maybeAdj of
    Nothing -> return (mempty, mempty)
    Just _v -> do
      (_v', stms) <- runBinderT' $ letExp "reshape_adj" (BasicOp (Reshape change _v))
      return (M.singleton v _v', stms)
revStm (Let Pattern {} _ (BasicOp Assert {})) =
  return (mempty, mempty)
revStm stm@(Let (Pattern [] [pe]) _ (Apply f args _ _))
  | Just (ret, argts) <- M.lookup f builtInFunctions = do
    (pe_adj, us1, s1) <- inScopeOf stm $ lookupAdj $ patElemName pe
    (contribs, contribs_stms) <- runBinder $ do
      let arg_pes = zipWith primExpFromSubExp argts (map fst args)
          pe_adj' = primExpFromSubExp ret (Var pe_adj)

      case pdBuiltin f arg_pes of
        Nothing ->
          error $ "No partial derivative defined for builtin function: " ++ pretty f
        Just derivs ->
          mapM (letExp "contrib" <=< toExp . (pe_adj' ~*~)) derivs

    let updateArgAdj (Var x, _) x_contrib = Just <$> updateAdjoint x x_contrib
        updateArgAdj _ _ = pure Nothing

    (_, us2, s2) <-
      inScopeOf contribs_stms $ unzip3 . catMaybes <$> zipWithM updateArgAdj args contribs

    pure
      ( mconcat us2 <> us1,
        s1 <> contribs_stms <> mconcat s2
      )
revStm stm = error $ "unsupported stm: " ++ pretty stm ++ "\n\n\n" ++ show stm

revFwdStms :: Stms SOACS -> ADM (Stms SOACS)
revFwdStms = fmap mconcat . mapM revFwdStm . stmsToList

revStms :: Stms SOACS -> ADM (M.Map VName VName, Stms SOACS, Stms SOACS)
revStms all_stms
  | Just (stms, stm) <- stmsLast all_stms = do
    stm' <- revFwdStm stm
    (u, _stm) <- inScopeOf stm' $ revStm stm
    (us, stms', _stms) <- inScopeOf _stm $ revStms stms
    pure (us <> u, stms' <> stm', _stm <> _stms)
  | otherwise = pure (M.empty, mempty, mempty)

revStms' :: Stms SOACS -> ADM (M.Map VName VName, Stms SOACS)
revStms' stms = do
  (us, stms_adj) <- unzip <$> mapM revStm (stmsToList stms)
  pure (mconcat us, mconcat stms_adj)

revBody :: Body -> ADM (M.Map VName VName, Body, Body)
revBody b@(Body desc stms res) = do
  (us, stms', _stms) <- inScopeOf stms $ revStms stms
  let fv = namesToList $ freeIn b
      us' = M.filterWithKey (\k _ -> k `elem` fv) us
  let body' = Body desc _stms $ map Var $ M.elems us'
  return (us', Body desc stms' res, body')

revBody' :: Body -> ADM (M.Map VName VName, Body)
revBody' b@(Body desc stms _) = do
  (us, _stms) <- inScopeOf stms $ revStms' stms
  let fv = namesToList $ freeIn b
      us' = M.filterWithKey (\k _ -> k `elem` fv) us
  let body' = Body desc _stms $ map Var $ M.elems us'
  return (us, body')

revVJP :: MonadFreshNames m => Scope SOACS -> Lambda -> m Lambda
revVJP scope (Lambda params body@(Body () stms res) _) = do
  let initial_renv = REnv {tans = mempty, envScope = scope}
  flip runADM initial_renv . localScope (scopeOfLParams params) . inScopeOf stms $ do
    let rvars = subExpVars res
    params_adj <- forM rvars $ \v -> do
      v_adj <- adjVName v
      insAdj v v_adj
      Param v_adj <$> lookupType v

    (_body_us, Body () fwd_stms _, Body () rev_stms _) <- revBody body

    (params_adjs, _, params_adjs_stms) <-
      unzip3 <$> mapM (lookupAdj . paramName) params

    Body () rev_stms' rev_adj_res <-
      renameBody $ Body () (rev_stms <> mconcat params_adjs_stms) (map Var params_adjs)

    let lam =
          Lambda
            (params ++ params_adj)
            (Body () (fwd_stms <> rev_stms') rev_adj_res)
            $ map paramType params

    pure lam