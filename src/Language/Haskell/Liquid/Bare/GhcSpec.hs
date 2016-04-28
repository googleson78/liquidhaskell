{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ViewPatterns              #-}

module Language.Haskell.Liquid.Bare.GhcSpec (
    makeGhcSpec
  ) where

-- import Debug.Trace (trace)
import           Prelude                                    hiding (error)
import           CoreSyn                                    hiding (Expr)
import qualified CoreSyn
import           HscTypes
import           Id
import           NameSet
import           Name
import           TyCon
import           Var
import           TysWiredIn

import           DataCon                                    (DataCon)

import           Control.Monad.Reader
import           Control.Monad.State
import           Data.Bifunctor
import           Data.Maybe


import           Control.Monad.Except                       (catchError)
import           TypeRep                                    (Type(TyConApp))

import qualified Control.Exception                          as Ex
import qualified Data.List                                  as L
import qualified Data.HashMap.Strict                        as M
import qualified Data.HashSet                               as S

import           Language.Fixpoint.Misc                     (applyNonNull, thd3)

import           Language.Fixpoint.Types                    hiding (Error)

import           Language.Haskell.Liquid.Types.Dictionaries
import           Language.Haskell.Liquid.GHC.Misc           (showPpr, getSourcePosE, getSourcePos, sourcePosSrcSpan, isDataConId)
import           Language.Haskell.Liquid.Types.PredType     (makeTyConInfo)
import           Language.Haskell.Liquid.Types.RefType
import           Language.Haskell.Liquid.Types
import           Language.Haskell.Liquid.Misc               (firstM, inserts, mapSnd, secondM)
import           Language.Haskell.Liquid.WiredIn


import qualified Language.Haskell.Liquid.Measure            as Ms

import           Language.Haskell.Liquid.Bare.Check
import           Language.Haskell.Liquid.Bare.DataType
import           Language.Haskell.Liquid.Bare.Env
import           Language.Haskell.Liquid.Bare.Existential
import           Language.Haskell.Liquid.Bare.Measure
import           Language.Haskell.Liquid.Bare.Axiom
import           Language.Haskell.Liquid.Bare.Misc          (makeSymbols, mkVarExpr)
import           Language.Haskell.Liquid.Bare.Plugged
import           Language.Haskell.Liquid.Bare.RTEnv
import           Language.Haskell.Liquid.Bare.Spec
import           Language.Haskell.Liquid.Bare.SymSort
import           Language.Haskell.Liquid.Bare.RefToLogic
import           Language.Haskell.Liquid.Bare.Lookup        (lookupGhcTyCon)

--------------------------------------------------------------------------------
makeGhcSpec :: Config
            -> ModName
            -> [CoreBind]
            -> [Var]
            -> [Var]
            -> NameSet
            -> HscEnv
            -> Either Error LogicMap
            -> [(ModName,Ms.BareSpec)]
            -> IO (CompSpec, TargetSpec)
--------------------------------------------------------------------------------
makeGhcSpec cfg name cbs vars defVars exports env lmap specs

  = do (csp, tsp)       <- throwLeft =<< execBare act initEnv
       let renv          = ghcSpecEnv csp
       let (csp', tsp')  = postProcess cbs renv csp tsp
       let errs          = checkGhcSpec specs renv csp' tsp'
       applyNonNull (return (csp', tsp')) Ex.throw errs
  where
    act       = makeGhcSpec' cfg cbs vars defVars exports specs
    throwLeft = either Ex.throw return
    initEnv   = BE name mempty mempty mempty env lmap' mempty mempty
    lmap'     = case lmap of {Left e -> Ex.throw e; Right x -> x `mappend` listLMap}

listLMap :: LogicMap
listLMap = toLogicMap [(nilName, [], hNil),
                       (consName, [x, xs], hCons (EVar <$> [x,xs]))
                      ]
  where
    x  = symbol "x"
    xs = symbol "xs"
    hNil    = mkEApp (dummyLoc $ symbol nilDataCon ) []
    hCons   = mkEApp (dummyLoc $ symbol consDataCon)

postProcess :: [CoreBind] -> SEnv SortedReft -> CompSpec -> TargetSpec -> (CompSpec, TargetSpec)
postProcess cbs specEnv csp@(CS {..}) tsp@(TS {..})
  = ( csp { tySigs     = tySigs'
          , asmSigs    = asmSigs'
          , dicts      = dicts'
          , invariants = invs'
          , meas       = meas'
          , inSigs     = inSigs' }
    , tsp { texprs     = ts } )
  where
    (sigs, ts')     = replaceLocalBinds tcEmbeds tyconEnv tySigs texprs specEnv cbs
    (assms, ts'')   = replaceLocalBinds tcEmbeds tyconEnv asmSigs ts'   specEnv cbs
    (insigs, ts)    = replaceLocalBinds tcEmbeds tyconEnv inSigs  ts''  specEnv cbs
    tySigs'         = M.map (addTyConInfo tcEmbeds tyconEnv <$>) sigs
    asmSigs'        = M.map (addTyConInfo tcEmbeds tyconEnv <$>) assms
    inSigs'         = M.map (addTyConInfo tcEmbeds tyconEnv <$>) insigs
    dicts'          = dmapty (addTyConInfo tcEmbeds tyconEnv) dicts
    invs'           = (addTyConInfo tcEmbeds tyconEnv <$>) <$> invariants
    meas'           = mapSnd (fmap (addTyConInfo tcEmbeds tyconEnv) . txRefSort tyconEnv tcEmbeds) <$> meas

ghcSpecEnv :: CompSpec -> SEnv SortedReft
ghcSpecEnv sp        = fromListSEnv binds
  where
    emb              = tcEmbeds sp
    binds            =  [(x,        rSort t) | (x, Loc _ _ t) <- meas sp]
                     ++ [(symbol v, rSort t) | (v, Loc _ _ t) <- M.toList $ ctors sp]
                     ++ [(x,        vSort v) | (x, v) <- freeSyms sp, isConLikeId v]
                     -- ++ [(val x   , rSort stringrSort) | Just (ELit x s) <- mkLit <$> lconsts, isString s]
    rSort            = rTypeSortedReft emb
    vSort            = rSort . varRSort
    varRSort         :: Var -> RSort
    varRSort         = ofType . varType
    --lconsts          = literals cbs
    --stringrSort      :: RSort
    --stringrSort      = ofType stringTy
    --isString s       = rTypeSort emb stringrSort == s

------------------------------------------------------------------------------------------------
makeGhcSpec' :: Config -> [CoreBind] -> [Var] -> [Var] -> NameSet -> [(ModName, Ms.BareSpec)] -> BareM (CompSpec, TargetSpec)
------------------------------------------------------------------------------------------------
makeGhcSpec' cfg cbs vars defVars exports specs
  = do name          <- modName <$> get
       makeRTEnv  specs
       (datacons, dcSs, recSs, tyi, embs) <- makeGhcSpecCHOP1 specs
       makeBounds embs name defVars cbs specs
       modify                                   $ \be -> be { tcEnv = tyi }
       (cls, mts)                              <- second mconcat . unzip . mconcat <$> mapM (makeClasses name cfg vars) specs
       (measures, cms', ms', cs', xs')         <- makeGhcSpecCHOP2 cbs specs dcSs datacons cls embs
       (invs, ialias, sigs, asms)              <- makeGhcSpecCHOP3 cfg vars defVars specs name mts embs
       quals   <- mconcat <$> mapM makeQualifiers specs
       syms                                    <- makeSymbols (varInModule name) (vars ++ map fst cs') xs' (sigs ++ asms ++ cs') ms' (invs ++ (snd <$> ialias))
       let su  = mkSubst [ (x, mkVarExpr v) | (x, v) <- syms]
       secondM (makeGhcSpec0 cfg defVars exports name) (emptyCompSpec, emptyTargetSpec)
         >>= firstM (makeGhcSpec1 vars defVars embs tyi exports name sigs (recSs ++ asms) cs' ms' cms' su)
         >>= makeGhcSpec2 invs ialias measures su
         >>= makeGhcSpec3 (datacons ++ cls) embs syms
         >>= firstM (makeSpecDictionaries embs vars specs)
         >>= firstM (makeGhcAxioms embs cbs name specs)
         >>= firstM (makeExactDataCons name (exactDC cfg) (snd <$> syms))
         -- This step need the updated logic map, ie should happen after makeGhcAxioms
         >>= makeGhcSpec4 quals defVars specs name su
         >>= secondM addProofType


addProofType :: TargetSpec -> BareM TargetSpec
addProofType tsp = do
  tycon <- (Just <$> lookupGhcTyCon (dummyLoc proofTyConName)) `catchError` (\_ -> return Nothing)
  return $ tsp { proofType = (`TyConApp` []) <$> tycon }


makeExactDataCons :: ModName -> Bool -> [Var] -> CompSpec -> BareM CompSpec
makeExactDataCons n flag vs spec
  | flag      = return $ spec {tySigs = inserts (tySigs spec) xts}
  | otherwise = return spec
  where
    xts       = makeExact <$> filter isDataConId (filter (varInModule n) vs)

varInModule :: (Show a, Show a1) => a -> a1 -> Bool
varInModule n v = L.isPrefixOf (show n) $ show v

makeExact :: Var -> (Var, LocSpecType)
makeExact x = (x, dummyLoc . fromRTypeRep $ trep{ty_res = res, ty_binds = xs})
  where
    t    :: SpecType
    t    = ofType $ varType x
    trep = toRTypeRep t
    xs   = zipWith (\_ i -> (symbol ("x" ++ show i))) (ty_args trep) [1..]

    res  = ty_res trep `strengthen` MkUReft ref mempty mempty
    vv   = vv_
    x'   = symbol x --  simpleSymbolVar x
    ref  = Reft (vv, PAtom Eq (EVar vv) eq)
    eq   | null (ty_vars trep) && null xs = EVar x'
         | otherwise = mkEApp (dummyLoc x') (EVar <$> xs)


makeGhcAxioms :: TCEmb TyCon -> [CoreBind] -> ModName -> [(ModName, Ms.BareSpec)] -> CompSpec -> BareM CompSpec
makeGhcAxioms tce cbs name bspecs sp = makeAxioms tce cbs sp spec
  where
    spec = fromMaybe mempty $ lookup name bspecs

makeAxioms :: TCEmb TyCon -> [CoreBind] -> CompSpec -> Ms.BareSpec -> BareM CompSpec
makeAxioms tce cbs spec sp
  = do lmap          <- logicEnv <$> get
       (ms, tys, as) <- unzip3 <$> mapM (makeAxiom tce lmap cbs) (S.toList $ Ms.axioms sp)
       lmap'         <- logicEnv <$> get
       return $ spec { meas     = ms         ++  meas   spec
                     , asmSigs  = inserts (asmSigs spec) (concat tys)
                     , axioms   = concat as  ++ axioms spec
                     , logicMap = lmap' }


makeGhcSpec0 :: Config
             -> [Var]
             -> NameSet
             -> ModName
             -> TargetSpec
             -> BareM TargetSpec
makeGhcSpec0 cfg defVars exports name sp
  = do targetVars <- makeTargetVars name defVars $ binders cfg
       return      $ sp { exports = exports
                        , tgtVars = targetVars }

makeGhcSpec1 :: [Var]
             -> [Var]
             -> TCEmb TyCon
             -> M.HashMap TyCon RTyCon
             -> NameSet
             -> ModName
             -> [(Var,Located (RRType RReft))]
             -> [(Var,Located (RRType RReft))]
             -> [(Var,Located (RRType RReft))]
             -> [(Symbol,Located (RRType Reft))]
             -> [(Symbol,Located (RRType Reft))]
             -> Subst
             -> CompSpec
             -> BareM CompSpec
makeGhcSpec1 vars defVars embs tyi exports name sigs asms cs' ms' cms' su sp
  = do tySigs      <- M.fromList <$> (makePluggedSigs name embs tyi exports $ tx sigs)
       asmSigs     <- M.fromList <$> (makePluggedAsmSigs embs tyi $ tx asms)
       ctors       <- M.fromList <$> (makePluggedAsmSigs embs tyi $ tx cs')
       lmap        <- logicEnv <$> get
       inlmap      <- inlines  <$> get
       let ctors'   = M.map (txRefToLogic lmap inlmap <$>) ctors
       return $ sp { tySigs     = M.filterWithKey (\v _ -> v `elem` vs) tySigs
                   , asmSigs    = M.filterWithKey (\v _ -> v `elem` vs) asmSigs
                   , ctors      = M.filterWithKey (\v _ -> v `elem` vs) ctors'
                   , meas       = tx' $ tx $ ms' ++ varMeasures vars ++ cms' }
    where
      tx   = fmap . mapSnd . subst $ su
      tx'  = fmap (mapSnd $ fmap uRType)
      vs   = vars ++ defVars

makeGhcSpec2 :: Monad m
             => [LocSpecType]
             -> [(LocSpecType,LocSpecType)]
             -> MSpec SpecType DataCon
             -> Subst
             -> (CompSpec, TargetSpec)
             -> m (CompSpec, TargetSpec)
makeGhcSpec2 invs ialias measures su (csp, tsp)
  = return
    ( csp { invariants = subst su invs
          , ialiases   = subst su ialias
          }
    , tsp { measures   = subst su
                           <$> M.elems (Ms.measMap measures)
                            ++ Ms.imeas measures
          }
    )

makeGhcSpec3 :: [(DataCon, DataConP)] -> TCEmb TyCon -> [(t, Var)]
             -> (CompSpec, TargetSpec) -> BareM (CompSpec, TargetSpec)
makeGhcSpec3 datacons embs syms (csp, tsp)
  = do tcEnv       <- tcEnv    <$> get
       lmap        <- logicEnv <$> get
       inlmap      <- inlines  <$> get
       let dcons'   = mapSnd (txRefToLogic lmap inlmap) <$> datacons
       return
         ( csp { tyconEnv   = tcEnv
               , tcEmbeds   = embs
               , freeSyms   = [(symbol v, v) | (_, v) <- syms] }
         , tsp { dconsP     = dcons' }
         )

makeGhcSpec4 :: [Qualifier]
             -> [Var]
             -> [(ModName,Ms.Spec ty bndr)]
             -> ModName
             -> Subst
             -> (CompSpec, TargetSpec)
             -> BareM (CompSpec, TargetSpec)
makeGhcSpec4 quals defVars specs name su (csp, tsp)
  = do decr'   <- mconcat <$> mapM (makeHints defVars . snd) specs
       texprs' <- mconcat <$> mapM (makeTExpr defVars . snd) specs
       lazies  <- mkThing makeLazy
       lvars'  <- mkThing makeLVar
       asize'  <- S.fromList <$> makeASize
       hmeas   <- mkThing makeHIMeas
       let msgs = strengthenHaskellMeasures hmeas
       lmap    <- logicEnv <$> get
       inlmap  <- inlines  <$> get
       let tx   = M.map (txRefToLogic lmap inlmap <$>)
       let mtx  = txRefToLogic lmap inlmap
       return
        ( csp { qualifiers = subst su quals
              , tySigs     = tx $ tySigs  csp
              , asmSigs    = tx $ asmSigs csp
              , inSigs     = tx $ M.fromList $ msgs
              }
        , tsp { decr       = decr'
              , texprs     = texprs'
              , lvars      = lvars'
              , autosize   = asize'
              , lazy       = lazies
              , measures   = mtx <$> measures tsp
              }
        )
    where
       mkThing mk = S.fromList . mconcat <$> sequence [ mk defVars s | (m, s) <- specs, m == name ]
       makeASize  = mapM lookupGhcTyCon [v | (m, s) <- specs, m == name, v <- S.toList (Ms.autosize s)]

makeGhcSpecCHOP1
  :: [(ModName,Ms.Spec ty bndr)]
  -> BareM ([(DataCon,DataConP)],[Measure SpecType DataCon],[(Var,Located SpecType)],M.HashMap TyCon RTyCon,TCEmb TyCon)
makeGhcSpecCHOP1 specs
  = do (tcs, dcs)      <- mconcat <$> mapM makeConTypes specs
       let tycons       = tcs        ++ wiredTyCons
       let tyi          = makeTyConInfo tycons
       embs            <- mconcat <$> mapM makeTyConEmbeds specs
       datacons        <- makePluggedDataCons embs tyi (concat dcs ++ wiredDataCons)
       let dcSelectors  = concatMap makeMeasureSelectors datacons
       recSels         <- makeRecordSelectorSigs datacons
       return             (second val <$> datacons, dcSelectors, recSels, tyi, embs)

makeGhcSpecCHOP3 :: Config -> [Var] -> [Var] -> [(ModName, Ms.BareSpec)]
                 -> ModName -> [(ModName, Var, LocSpecType)]
                 -> TCEmb TyCon
                 -> BareM ( [LocSpecType]
                          , [(LocSpecType, LocSpecType)]
                          , [(Var, LocSpecType)]
                          , [(Var, LocSpecType)] )
makeGhcSpecCHOP3 cfg vars defVars specs name mts embs
  = do sigs'   <- mconcat <$> mapM (makeAssertSpec name cfg vars defVars) specs
       asms'   <- mconcat <$> mapM (makeAssumeSpec name cfg vars defVars) specs
       invs    <- mconcat <$> mapM makeInvariants specs
       ialias  <- mconcat <$> mapM makeIAliases   specs
       let dms  = makeDefaultMethods vars mts
       tyi     <- gets tcEnv
       let sigs = [ (x, txRefSort tyi embs $ fmap txExpToBind t) | (_, x, t) <- sigs' ++ mts ++ dms ]
       let asms = [ (x, txRefSort tyi embs $ fmap txExpToBind t) | (_, x, t) <- asms' ]
       return     (invs, ialias, sigs, asms)

makeGhcSpecCHOP2 :: [CoreBind]
                 -> [(ModName, Ms.BareSpec)]
                 -> [Measure SpecType DataCon]
                 -> [(DataCon, DataConP)]
                 -> [(DataCon, DataConP)]
                 -> TCEmb TyCon
                 -> BareM ( MSpec SpecType DataCon
                          , [(Symbol, Located (RRType Reft))]
                          , [(Symbol, Located (RRType Reft))]
                          , [(Var,    LocSpecType)]
                          , [Symbol] )
makeGhcSpecCHOP2 cbs specs dcSelectors datacons cls embs
  = do measures'   <- mconcat <$> mapM makeMeasureSpec specs
       tyi         <- gets tcEnv
       name        <- gets modName
       mapM_ (makeHaskellInlines embs cbs name) specs
       hmeans      <- mapM (makeHaskellMeasures embs cbs name) specs
       let measures = mconcat (Ms.wiredInMeasures:measures':Ms.mkMSpec' dcSelectors:hmeans)
       let (cs, ms) = makeMeasureSpec' measures
       let cms      = makeClassMeasureSpec measures
       let cms'     = [ (x, Loc l l' $ cSort t) | (Loc l l' x, t) <- cms ]
       let ms'      = [ (x, Loc l l' t) | (Loc l l' x, t) <- ms, isNothing $ lookup x cms' ]
       let cs'      = [ (v, txRefSort' v tyi embs t) | (v, t) <- meetDataConSpec cs (datacons ++ cls)]
       let xs'      = val . fst <$> ms
       return (measures, cms', ms', cs', xs')

txRefSort'
  :: NamedThing a
  => a -> TCEnv -> TCEmb TyCon -> SpecType -> Located SpecType
txRefSort' v tyi embs t = txRefSort tyi embs (atLoc' v t)

atLoc' :: NamedThing a1 => a1 -> a -> Located a
atLoc' v = Loc (getSourcePos v) (getSourcePosE v)

data ReplaceEnv = RE { _re_env  :: M.HashMap Symbol Symbol
                     , _re_fenv :: SEnv SortedReft
                     , _re_emb  :: TCEmb TyCon
                     , _re_tyi  :: M.HashMap TyCon RTyCon
                     }

type ReplaceState = ( M.HashMap Var LocSpecType
                    , M.HashMap Var [Located Expr]
                    )

type ReplaceM = ReaderT ReplaceEnv (State ReplaceState)

replaceLocalBinds :: TCEmb TyCon
                  -> M.HashMap TyCon RTyCon
                  -> M.HashMap Var LocSpecType
                  -> [(Var, [Located Expr])]
                  -> SEnv SortedReft
                  -> CoreProgram
                  -> (M.HashMap Var LocSpecType, [(Var, [Located Expr])])
replaceLocalBinds emb tyi sigs texprs senv cbs
  = (s, M.toList t)
  where
    (s, t) = execState (runReaderT (mapM_ (`traverseBinds` return ()) cbs)
                                   (RE M.empty senv emb tyi))
                       (sigs, M.fromList texprs)

traverseExprs
  :: CoreSyn.Expr Var -> ReaderT ReplaceEnv (State ReplaceState) ()
traverseExprs (Let b e)
  = traverseBinds b (traverseExprs e)
traverseExprs (Lam b e)
  = withExtendedEnv [b] (traverseExprs e)
traverseExprs (App x y)
  = traverseExprs x >> traverseExprs y
traverseExprs (Case e _ _ as)
  = traverseExprs e >> mapM_ (traverseExprs . thd3) as
traverseExprs (Cast e _)
  = traverseExprs e
traverseExprs (Tick _ e)
  = traverseExprs e
traverseExprs _
  = return ()

traverseBinds
  :: Bind Var
  -> ReaderT ReplaceEnv (State ReplaceState) b
  -> ReaderT ReplaceEnv (State ReplaceState) b
traverseBinds b k = withExtendedEnv (bindersOf b) $ do
  mapM_ traverseExprs (rhssOfBind b)
  k

-- RJ: this function is incomprehensible, what does it do?!
withExtendedEnv
  :: Foldable t
  => t Var
  -> ReaderT ReplaceEnv (State ReplaceState) b
  -> ReaderT ReplaceEnv (State ReplaceState) b
withExtendedEnv vs k
  = do RE env' fenv' emb tyi <- ask
       let env  = L.foldl' (\m v -> M.insert (varShortSymbol v) (symbol v) m) env' vs
           fenv = L.foldl' (\m v -> insertSEnv (symbol v) (rTypeSortedReft emb (ofType $ varType v :: RSort)) m) fenv' vs
       withReaderT (const (RE env fenv emb tyi)) $ do
         mapM_ replaceLocalBindsOne vs
         k

varShortSymbol :: Var -> Symbol
varShortSymbol = symbol . takeWhile (/= '#') . showPpr . getName

-- RJ: this function is incomprehensible
replaceLocalBindsOne :: Var -> ReplaceM ()
replaceLocalBindsOne v
  = do mt <- gets (M.lookup v . fst)
       case mt of
         Nothing -> return ()
         Just (Loc l l' (toRTypeRep -> t@(RTypeRep {..}))) -> do
           (RE env' fenv emb tyi) <- ask
           let f m k = M.lookupDefault k k m
           let (env,args) = L.mapAccumL (\e (v, t) -> (M.insert v v e, substa (f e) t))
                             env' (zip ty_binds ty_args)
           let res  = substa (f env) ty_res
           let t'   = fromRTypeRep $ t { ty_args = args, ty_res = res }
           let msg  = ErrTySpec (sourcePosSrcSpan l) (pprint v) t'
           case checkTy msg emb tyi fenv (Loc l l' t') of
             Just err -> Ex.throw err
             Nothing -> modify (first $ M.insert v (Loc l l' t'))
           mes <- gets (M.lookup v . snd)
           case mes of
             Nothing -> return ()
             Just es -> do
               let es'  = substa (f env) es
               case checkTerminationExpr emb fenv (v, Loc l l' t', es') of
                 Just err -> Ex.throw err
                 Nothing  -> modify (second $ M.insert v es')
