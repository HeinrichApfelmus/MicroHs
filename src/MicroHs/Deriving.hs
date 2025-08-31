module MicroHs.Deriving(deriveStrat, expandField, mkGetName, etaReduce, mkTypeableInst) where
import qualified Prelude(); import MHSPrelude
import Data.Char
import Data.Function
import Data.List
import Data.Maybe (fromMaybe)
import MicroHs.Builtin
import MicroHs.Expr
import MicroHs.Fixity (defaultFixity)
import MicroHs.Ident
import qualified MicroHs.IdentMap as M
import MicroHs.List
import MicroHs.Names
import MicroHs.TCMonad
import Debug.Trace

-- Deriving runs when types level names are resolved, but not value level names.
-- To get access to names that might not be in scope, the module Mhs.Builtin
-- re-exports all names needed here.  This module is automagically imported as B@
-- Generated names should be like
--   type/class names fully qualified
--   method names (on lhs) unqualified
--   constructor names in the derived type unqualified
--   all other names should be qualified with B@

deriveStrat :: StandM -> Bool -> LHS -> [Constr] -> DerStrategy -> (Int, EConstraint) -> T [EDef]
deriveStrat mctx newt lhs cs strat (narg, cls) =  -- narg is the number of arguments that need eta reducing
--  trace ("deriveStrat " ++ show (mctx, newt, lhs, cs, strat, narg, cls)) $
  case strat of
    DerNone | newt && useNewt cls -> newtypeDer  mctx narg lhs (cs!!0) cls Nothing
            | otherwise           -> deriveNoHdr mctx narg lhs cs cls
    DerStock                      -> deriveNoHdr mctx narg lhs cs cls
    DerNewtype | newt             -> newtypeDer  mctx narg lhs (cs!!0) cls Nothing
    DerAnyClass                   -> anyclassDer mctx narg lhs cls
    DerVia via | newt             -> newtypeDer  mctx narg lhs (cs!!0) cls (Just via)
    _                             -> cannotDerive lhs cls
  where useNewt d = unIdent (getAppCon d) `notElem`
          ["Data.Data.Data", "Data.Typeable.Typeable", "GHC.Generics.Generic",
           "Language.Haskell.TH.Syntax.Lift", "Text.Read.Internal.Read", "Text.Show.Show"]

type DeriverT = Int -> LHS -> [Constr] -> EConstraint -> T [EDef]   -- Bool indicates a newtype
type Deriver = StandM -> DeriverT
-- StandM is
--   Nothing for regular deriving
--   Just (instance-context, qualified-type-name) for standalone
type StandM = Maybe (EConstraint, Ident)

derivers :: [(String, Deriver)]
derivers =
  [("Data.Bounded.Bounded",            derBounded)
  ,("Data.Enum_Class.Enum",            derEnum)
  ,("Data.Data.Data",                  derData)
  ,("Data.Eq.Eq",                      derEq)
  ,("Data.Functor.Functor",            derNotYet) -- derFunctor)
  ,("Data.Ix.Ix",                      derIx)
  ,("Data.Ord.Ord",                    derOrd)
  ,("Data.Typeable.Typeable",          derTypeable)
  ,("GHC.Generics.Generic",            derNotYet)
  ,("Language.Haskell.TH.Syntax.Lift", derLift)
  ,("Text.Read.Internal.Read",         derRead)
  ,("Text.Show.Show",                  derShow)
  ]

deriveNoHdr :: StandM -> DeriverT
deriveNoHdr mctx narg lhs cs d = do
--  traceM ("deriveNoHdr " ++ show d)
  case getDeriver d of
    Just f -> f mctx narg lhs cs d
    _      -> cannotDerive lhs d

getDeriver :: EConstraint -> Maybe Deriver
getDeriver d = lookup (unIdent $ getAppCon d) derivers

derNotYet :: Deriver
derNotYet _ _ _ _ d = do
  notYet d
  return []

notYet :: EConstraint -> T ()
notYet d =
  traceM ("Warning: cannot derive " ++ show d ++ " yet, " ++ showSLoc (getSLoc d))

-- We will never have Template Haskell, but we pretend we can derive Lift for it.
derLift :: Deriver
derLift _ _ _ _ _ = return []

-- Get the name of the module where the type is defined.
-- For regular deriving it's the current module, for standalone it's elsewhere.
getDefModuleName :: StandM -> T IdentModule
getDefModuleName mctx = maybe (gets moduleName) (pure . qualOf . snd) mctx

-- Get a fixity lookup function.
-- The fixity table has qualified names as keys, so qualify first.
getFixLookup :: StandM -> T (Ident -> Fixity)
getFixLookup mctx = do
  mn <- getDefModuleName mctx
  fxt <- gets fixTable
  pure $ \ i -> fromMaybe defaultFixity (M.lookup (qualIdent mn i) fxt)

--------------------------------------------

expandField :: EDef -> T [EDef]
expandField def@(Data    lhs cs _) = (++ [def]) <$> genHasFields lhs cs
expandField def@(Newtype lhs  c _) = (++ [def]) <$> genHasFields lhs [c]
expandField def                    = return [def]

genHasFields :: LHS -> [Constr] -> T [EDef]
genHasFields lhs cs = do
  let fldtys = nubBy ((==) `on` fst) [ (fld, ty) | Constr _ _ _ _ (Right fs) <- cs, (fld, (_, ty)) <- fs ]
--      flds = map fst fldtys
  concat <$> mapM (genHasField lhs cs) fldtys

genHasField :: LHS -> [Constr] -> (Ident, EType) -> T [EDef]
genHasField (tycon, iks) cs (fld, fldty) = do
  mn <- gets moduleName
  let loc = getSLoc tycon
      qtycon = qualIdent mn tycon
      eFld = EVar fld
      ufld = unIdent fld
      undef = mkExn loc ufld "recSelError"
      iHasField = mkIdentSLoc loc nameHasField
      iSetField = mkIdentSLoc loc nameSetField
      igetField = mkIdentSLoc loc namegetField
      isetField = mkIdentSLoc loc namesetField
      hdrGet = eForall iks $ eApp3 (EVar iHasField)
                                   (ELit loc (LStr ufld))
                                   (eApps (EVar qtycon) (map (EVar . idKindIdent) iks))
                                   fldty
      hdrSet = eForall iks $ eApp3 (EVar iSetField)
                                   (ELit loc (LStr ufld))
                                   (eApps (EVar qtycon) (map (EVar . idKindIdent) iks))
                                   fldty
      conEqnGet (Constr _ _ c _ (Left ts))   = eEqn [eApps (EVar c) (map (const eDummy) ts)] undef
      conEqnGet (Constr _ _ c _ (Right fts)) = eEqn [conApp] $ if fld `elem` fs then rhs else undef
        where fs = map fst fts
              conApp = eApps (EVar c) (map EVar fs)
              rhs = eFld
      conEqnSet (Constr _ _ c _ (Left ts))   = eEqn [eDummy, eApps (EVar c) (map (const eDummy) ts)] undef
      conEqnSet (Constr _ _ c _ (Right fts)) = eEqn [eDummy, conApp] $ if fld `elem` fs then rhs else undef
        where fs = map fst fts
              conApp = eApps (EVar c) (map EVar fs)
              rhs = eLam [eFld] conApp
      getName = mkGetName tycon fld

      -- XXX A hack, we can't handle forall yet.
      validType EForall{} = False
      validType _ = True

  pure $ [ Sign [getName] $ eForall iks $ lhsToType (qtycon, iks) `tArrow` fldty
         , Fcn getName $ map conEqnGet cs ]
    ++ if not (validType fldty) then [] else
         [ Instance hdrGet [Fcn igetField [eEqn [eDummy] $ EVar getName] ] []
         , Instance hdrSet [Fcn isetField $ map conEqnSet cs] []
         ]

mkGetName :: Ident -> Ident -> Ident
mkGetName tycon fld = qualIdent (mkIdent "get") $ qualIdent tycon fld

--------------------------------------------

derTypeable :: Deriver
derTypeable mctx 0 (i, _) _ _ = do
  -- The module name we need is the current module for regular deriving,
  -- and the module of the type for standalone deriving.
  -- We use mctx to decide which it is.
  mn <- getDefModuleName mctx
  return [mkTypeableInst mn i]
derTypeable _ _ lhs _ e = cannotDerive lhs e

-- Generate a Typeable instance given a module and type/class name.
mkTypeableInst :: IdentModule -> Ident -> EDef
mkTypeableInst mn i =
  let
    loc = getSLoc i
    itypeRep  = mkIdentSLoc loc "typeRep"
    i_mkTyCon = mkBuiltin loc "_mkTyCon"
    etyp = EVar (mkIdentSLoc loc nameDataTypeableTypeable)
    hdr = EApp etyp (EVar $ qualIdent mn i)
    mdl = ELit loc $ LStr $ unIdent mn
    nam = ELit loc $ LStr $ unIdent i
    eqns = eEqns [] $ eAppI2 i_mkTyCon mdl nam
    inst = Instance hdr [Fcn itypeRep eqns] []
  in inst

--------------------------------------------

getFieldTys :: Either [SType] [ConstrField] -> [EType]
getFieldTys (Left ts) = map snd ts
getFieldTys (Right ts) = map (snd . snd) ts

-- If there is no mctx we use the default strategy to derive the instance context.
-- The default strategy basically is to require the class constraint for every
-- constructor argument (except direct recursion) with free type variables.
-- E.g.  data T = C a | D (a, Int) deriving Eq
-- will get context  (Eq a, Eq (a, Int))
-- Used for regular deriving, not standalone.
mkHdr :: StandM -> LHS -> [Constr] -> EConstraint -> T EConstraint
mkHdr (Just (ctx, _)) _ _ _ = return ctx
mkHdr _ lhs@(_, iks) cs cls = do
  ty <- mkLhsTy lhs
  let ctys :: [EType]  -- All top level types used by the constructors.
      ctys = nubBy eqEType [ tt | Constr evs _ _ _ flds <- cs, tt <- getFieldTys flds,
                            not $ null $ freeTyVars [tt] \\ map idKindIdent evs, not (eqEType ty tt) ]
  pure $ eForall iks $ addConstraints (map (tApp cls) ctys) $ tApp cls ty

-- Used for regular deriving, not standalone.
mkLhsTy :: LHS -> T EType
mkLhsTy (t, iks) = do
  mn <- gets moduleName
  return $ tApps (qualIdent mn t) $ map tVarK iks

mkPat :: Constr -> String -> (EPat, [Expr])
mkPat (Constr _ _ c _ flds) s =
  let n = either length length flds
      loc = getSLoc c
      vs = map (EVar . mkIdentSLoc loc . (s ++) . show) [1..n]
  in  (tApps c vs, vs)

cannotDerive :: LHS -> EConstraint -> T [EDef]
cannotDerive (c, _) e = tcError (getSLoc e) $ "Cannot derive " ++ showEType (EApp e (EVar c))

--------------------------------------------

derEq :: Deriver
derEq mctx 0 lhs cs eeq = do
  hdr <- mkHdr mctx lhs cs eeq
  let loc = getSLoc eeq
      mkEqn c =
        let (xp, xs) = mkPat c "x"
            (yp, ys) = mkPat c "y"
        in  eEqn [xp, yp] $ if null xs then eTrue else foldr1 eAnd $ zipWith eEq xs ys
      eqns = if null cs then [eEqn [eDummy, eDummy] eTrue] else map mkEqn cs ++ [eEqn [eDummy, eDummy] eFalse]
      iEq = mkIdentSLoc loc "=="
      eEq = eAppI2 (mkBuiltin loc "==")
      eAnd = eAppI2 (mkBuiltin loc "&&")
      eTrue = EVar $ mkBuiltin loc "True"
      eFalse = EVar $ mkBuiltin loc "False"
      inst = Instance hdr [Fcn iEq eqns] []
--  traceM $ showEDefs [inst]
  return [inst]
derEq _ _ lhs _ e = cannotDerive lhs e

--------------------------------------------

derOrd :: Deriver
derOrd mctx 0 lhs cs eord = do
  hdr <- mkHdr mctx lhs cs eord
  let loc = getSLoc eord
      mkEqn c =
        let (xp, xs) = mkPat c "x"
            (yp, ys) = mkPat c "y"
        in  [eEqn [xp, yp] $ if null xs then eEQ else foldr1 eComb $ zipWith eCompare xs ys
            ,eEqn [xp, eDummy] eLT
            ,eEqn [eDummy, yp] eGT]
      eqns = if null cs then [eEqn [eDummy, eDummy] eEQ] else concatMap mkEqn cs
      iCompare = mkIdentSLoc loc "compare"
      eCompare = eAppI2 (mkBuiltin loc "compare")
      eComb = eAppI2 (mkBuiltin loc "<>")
      eEQ = EVar $ mkBuiltin loc "EQ"
      eLT = EVar $ mkBuiltin loc "LT"
      eGT = EVar $ mkBuiltin loc "GT"
      inst = Instance hdr [Fcn iCompare eqns] []
--  traceM $ showEDefs [inst]
  return [inst]
derOrd _ _ lhs _ e = cannotDerive lhs e

--------------------------------------------

derBounded :: Deriver
derBounded mctx 0 lhs cs@(c0:_) ebnd = do
  hdr <- mkHdr mctx lhs cs ebnd
  let loc = getSLoc ebnd
      mkEqn bnd (Constr _ _ c _ flds) =
        let n = either length length flds
        in  eEqn [] $ tApps c (replicate n (EVar bnd))

      iMinBound = mkIdentSLoc loc "minBound"
      iMaxBound = mkIdentSLoc loc "maxBound"
      minEqn = mkEqn iMinBound c0
      maxEqn = mkEqn iMaxBound (last cs)
      inst = Instance hdr [Fcn iMinBound [minEqn], Fcn iMaxBound [maxEqn]] []
  -- traceM $ showEDefs [inst]
  return [inst]
derBounded _ _ lhs _ e = cannotDerive lhs e

--------------------------------------------

derEnum :: Deriver
derEnum mctx 0 lhs cs@(c0:_) enm | all isNullary cs = do
  hdr <- mkHdr mctx lhs cs enm
  let loc = getSLoc enm

      eFirstCon = case c0 of Constr _ _ c _ _ -> tCon c
      eLastCon = case last cs of Constr _ _ c _ _ -> tCon c

      iFromEnum = mkIdentSLoc loc "fromEnum"
      iToEnum = mkIdentSLoc loc "toEnum"
      iEnumFrom = mkIdentSLoc loc "enumFrom"
      iEnumFromThen = mkIdentSLoc loc "enumFromThen"
      iEnumFromTo = mkBuiltin loc "enumFromTo"
      iEnumFromThenTo = mkBuiltin loc "enumFromThenTo"
      enumFromEqn =
        -- enumFrom x = enumFromTo x (last cs)
        let x = EVar (mkIdentSLoc loc "x")
        in eEqn [x] (eAppI2 iEnumFromTo x eLastCon)
      enumFromThenEqn =
        -- enumFromThen x1 x2 = if fromEnum x2 >= fromEnum x1 then enumFromThenTo x1 x2 (last cs) else enumFromThenTo x1 x2 (head cs)
        let
          x1 = EVar (mkIdentSLoc loc "x1")
          x2 = EVar (mkIdentSLoc loc "x2")
        in eEqn [x1, x2] (EIf (eAppI2 (mkBuiltin loc ">=") (EApp (EVar iFromEnum) x2) (EApp (EVar iFromEnum) x1)) (eAppI3 iEnumFromThenTo x1 x2 eLastCon) (eAppI3 iEnumFromThenTo x1 x2 eFirstCon))
      inst = Instance hdr [Fcn iFromEnum (fromEnumEqns loc cs), Fcn iToEnum (toEnumEqns loc cs), Fcn iEnumFrom [enumFromEqn], Fcn iEnumFromThen [enumFromThenEqn]] []
  return [inst]
derEnum _ _ lhs _ e = cannotDerive lhs e

isNullary :: Constr -> Bool
isNullary (Constr _ _ _ _ flds) = either null null flds

fromEnumEqns :: SLoc -> [Constr] -> [Eqn]
fromEnumEqns loc cs = zipWith mkFrom cs [0..]
  where
    mkFrom (Constr _ _ c _ _) i = eEqn [EVar c] $ ELit loc (LInt i)

toEnumEqns :: SLoc -> [Constr] -> [Eqn]
toEnumEqns loc cs = zipWith mkTo cs [0..] ++ [eEqn [eDummy] $ eAppI (mkBuiltin loc "error") (ELit loc (LStr "toEnum: out of range"))]
  where
    mkTo (Constr _ _ c _ _) i = eEqn [ELit loc (LInt i)] $ EVar c

--------------------------------------------

derIx :: Deriver
derIx mctx 0 lhs cs@(c0:cs') eix = do
  hdr <- mkHdr mctx lhs cs eix
  let loc = getSLoc eix
      iRange       = mkIdentSLoc loc "range"
      iUnsafeIndex = mkIdentSLoc loc "unsafeIndex"
      iInRange     = mkIdentSLoc loc "inRange"
  if all isNullary cs then do
    let iToInt = mkIdentSLoc loc "toInt"
        iFromInt = mkIdentSLoc loc "fromInt"
        eToInt = eAppI iToInt
        eFromInt = eAppI iFromInt
        eEnumFromTo = eAppI2 (mkBuiltin loc "enumFromTo")
        eSub = eAppI2 (mkBuiltin loc "-")
        eAnd = eAppI2 (mkBuiltin loc "&&")
        eLE = eAppI2 (mkBuiltin loc "<=")
        x = EVar (mkIdentSLoc loc "x")
        y = EVar (mkIdentSLoc loc "y")
        z = EVar (mkIdentSLoc loc "z")
        w = EVar (mkIdentSLoc loc "w")
        rangeEqn = eEqn [ETuple [x, y]] $ EListish (LCompr (eFromInt z) [SBind z (eEnumFromTo (eToInt x) (eToInt y))])
        unsafeIndexEqn = eEqn [ETuple [x, eDummy], y] $ eSub (eToInt y) (eToInt x)
        inRangeEqn = eEqn [ETuple [x, y], z] $ ECase (eToInt z) [(w, oneAlt $ eAnd (eLE (eToInt x) w) (eLE w (eToInt y)))]
        inst = Instance hdr [Fcn iRange [rangeEqn], Fcn iUnsafeIndex [unsafeIndexEqn], Fcn iInRange [inRangeEqn]] [Fcn iToInt (fromEnumEqns loc cs), Fcn iFromInt (toEnumEqns loc cs)]
    return [inst]
  else if null cs' then do
    let Constr _ _ iC0 _ _ = c0
        eAnd = eAppI2 (mkBuiltin loc "&&")
        eAdd = eAppI2 (mkBuiltin loc "+")
        eMul = eAppI2 (mkBuiltin loc "*")
        iUnsafeRangeSize = mkIdentSLoc loc "unsafeRangeSize"
        (xp, xs) = mkPat c0 "x"
        (yp, ys) = mkPat c0 "y"
        (zp, zs) = mkPat c0 "z"
        rangeEqn = eEqn [ETuple [xp, yp]] $ EListish (LCompr (tApps iC0 zs) (zipWith3 (\x y z -> SBind z (eAppI iRange (ETuple [x, y]))) xs ys zs))
        unsafeIndexEqn =
          let mkUnsafeIndex x y z = eAppI2 iUnsafeIndex (ETuple [x, y]) z
              mkUnsafeRangeSize x y = eAppI iUnsafeRangeSize (ETuple [x, y])
          in eEqn [ETuple [xp, yp], zp] $ foldl (\acc (x, y, z) -> eAdd (mkUnsafeIndex x y z) (eMul (mkUnsafeRangeSize x y) acc)) (mkUnsafeIndex (head xs) (head ys) (head zs)) $ zip3 (tail xs) (tail ys) (tail zs)
        inRangeEqn = eEqn [ETuple [xp, yp], zp] $ foldr1 eAnd $ zipWith3 (\x y z -> eAppI2 iInRange (ETuple [x, y]) z) xs ys zs
        inst = Instance hdr [Fcn iRange [rangeEqn], Fcn iUnsafeIndex [unsafeIndexEqn], Fcn iInRange [inRangeEqn]] []
    return [inst]
  else
    cannotDerive lhs eix
derIx _ _ lhs _ e = cannotDerive lhs e

--------------------------------------------

derShow :: Deriver
derShow mctx 0 lhs cs eshow = do
  hdr <- mkHdr mctx lhs cs eshow
  fixLookup <- getFixLookup mctx  -- fixity lookup function.  Not used yet.
  let loc = getSLoc eshow
      mkEqn c@(Constr _ _ name isInfix fields) =
        let (xp, xs) = mkPat c "x"
        in  eEqn [varp, xp] $ showRHS name isInfix xs fields

      var = EVar . mkBuiltin loc
      varp = EVar $ mkIdentSLoc loc "p"
      lit = ELit loc

      iShowsPrec = mkIdentSLoc loc "showsPrec"
      eShowsPrec n = eApp2 (var "showsPrec") (lit (LInt n))
      eShowString s = EApp (var "showString") (lit (LStr s))
      eParen n = eApp2 (var "showParen") (eApp2 (var ">") varp (lit (LInt n)))
      eShowL s = foldr1 ejoin . intersperse (eShowString s)
      ejoin = eApp2 (var ".")

      showRHS nm _ [] _ = eShowString (unIdentPar nm)
      showRHS nm inf xs (Left   _) = showRHSN nm inf xs
      showRHS nm _ xs (Right fs) = showRHSR nm $ zip (map fst fs) xs

      showRHSN nm inf xs =
        if inf then
          let p = snd $ fixLookup nm
          in eParen p $ eShowL " " [eShowsPrec (p + 1) (xs !! 0), eShowString (unIdentTick nm), eShowsPrec (p + 1) (xs !! 1)]
        else
          eParen 10 $ eShowL " " $ eShowString (unIdentPar nm) : map (eShowsPrec 11) xs

      showRHSR nm fxs =
        eShowString (unIdentPar nm ++ " {") `ejoin`
        eShowL ", " (map fld fxs) `ejoin`
        eShowString "}"
          where fld (f, x) = eShowString (unIdentPar f ++ " = ") `ejoin` eShowsPrec 0 x

      eqns = map mkEqn cs
      inst = Instance hdr [Fcn iShowsPrec eqns] []
--  traceM $ showEDefs [inst]
  return [inst]
derShow _ _ lhs _ e = cannotDerive lhs e

unIdentPar :: Ident -> String
unIdentPar i =
  let s = unIdent i
  in  if isAlpha (head s) then s else "(" ++ s ++ ")"

unIdentTick :: Ident -> String
unIdentTick i =
  let s = unIdent i
  in  if isAlpha (head s) then "`" ++ s ++ "`" else s

--------------------------------------------

derRead :: Deriver
derRead mctx 0 lhs cs eread = do
  hdr <- mkHdr mctx lhs cs eread
  fixLookup <- getFixLookup mctx -- fixity lookup function
  let
    loc = getSLoc eread
    iReadPrec = mkIdentSLoc loc "readPrec"
    iReadList = mkIdentSLoc loc "readList"
    iReadListPrec = mkIdentSLoc loc "readListPrec"
    eReadListDefault = EVar (mkBuiltin loc "readListDefault")
    eReadListPrecDefault = EVar (mkBuiltin loc "readListPrecDefault")
    eParens = eAppI (mkBuiltin loc "parens")
    eChoice = eAppI2 (mkBuiltin loc "+++")
    ePrec n = eAppI2 (mkBuiltin loc "prec") (ELit loc (LInt n))
    iExpectP = mkBuiltin loc "expectP"
    eExpectIdent s = eAppI iExpectP (eAppI (mkBuiltin loc "Ident") (ELit loc (LStr s)))
    eExpectPunc s = eAppI iExpectP (eAppI (mkBuiltin loc "Punc") (ELit loc (LStr s)))
    eExpectSymbol s = eAppI iExpectP (eAppI (mkBuiltin loc "Symbol") (ELit loc (LStr s)))
    eReadField = eAppI (mkBuiltin loc "step") (EVar iReadPrec)
    eReadNamedField name = eAppI2 (mkBuiltin loc "readField") (ELit loc (LStr name)) (eAppI (mkBuiltin loc "reset") (EVar iReadPrec))
    eReturn = eAppI (mkBuiltin loc "return")
    ePfail = EVar (mkBuiltin loc "pfail")
    readConstr c@(Constr _ _ ident isInfix fields) =
      let (xe, xs) = mkPat c "x"
          name = unIdent ident
          readName = map SThen $ if isAlpha (head name) then [eExpectIdent name] else [eExpectPunc "(", eExpectSymbol name, eExpectPunc ")"]
          readNameInfix = map SThen $ if isAlpha (head name) then [eExpectPunc "`", eExpectIdent name, eExpectPunc "`"] else [eExpectSymbol name]
      in case fields of
        Left _ ->
          if isInfix then
            ePrec (snd $ fixLookup ident) $ EDo Nothing $ [SBind (xs !! 0) eReadField] ++ readNameInfix ++ [SBind (xs !! 1) eReadField, SThen (eReturn xe)]
          else
            ePrec 10 $ EDo Nothing $ readName ++ map (\x -> SBind x eReadField) xs ++ [SThen $ eReturn xe]
        Right fs -> ePrec 11 $ EDo Nothing $ readName ++ [SThen $ eExpectPunc "{"] ++ intersperse (SThen $ eExpectPunc ",") (zipWith (\(f, _) x -> SBind x (eReadNamedField (unIdentPar f))) fs xs) ++ [SThen $ eExpectPunc "}", SThen $ eReturn xe]
    readPrecEqn = eEqn [] $ if null cs then ePfail else eParens $ foldr1 eChoice (map readConstr cs)
    readListEqn = eEqn [] eReadListDefault
    readListPrecEqn = eEqn [] eReadListPrecDefault
    inst = Instance hdr [Fcn iReadPrec [readPrecEqn], Fcn iReadList [readListEqn], Fcn iReadListPrec [readListPrecEqn]] []
  return [inst]
derRead _ _ lhs _ e = cannotDerive lhs e

--------------------------------------------

-- Deriving for the fake Data class.
derData :: Deriver
derData mctx _ lhs cs edata = do
  notYet edata
  hdr <- mkHdr mctx lhs cs edata
  let
    inst = Instance hdr [] []
  return [inst]

--------------------------------------------

newtypeDer :: StandM -> Int -> LHS -> Constr -> EConstraint -> Maybe EConstraint -> T [EDef]
newtypeDer mctx narg (tycon, iks) c acls mvia = do
  let loc = getSLoc cls
      (clsIks, cls) = unForall acls
      oldty' =                           -- the underlying type, full
        case c of
          Constr [] [] _ _ (Left [(False, t)]) -> t
          Constr [] [] _ _ (Right [(_, (_, t))]) -> t
          _ -> error "newtypeDer"
--  traceM ("newtypeDer " ++ show (mctx, narg, tycon, iks, c, acls, mvia, oldty'))
  viaty <-
    case mvia of
      Just via -> return via
      Nothing  ->
        case etaReduce (takeEnd narg iks) oldty' of  -- the underlying type, eta reduced
          ([], rt) -> return rt
          _ -> tcError loc "Bad deriving"
  hdr <-
    case mctx of
      Nothing -> do
        let iks' = dropEnd narg iks
        newty <- mkLhsTy (tycon, iks')         -- the newtype, eta reduced
        -- XXX repeats what we might have done above
        oldty <- case etaReduce (takeEnd narg iks) oldty' of  -- the underlying type, eta reduced
                   ([], rt) -> return rt
                   _ -> tcError loc "Bad deriving"
        let ctxOld = tApp cls viaty
            coOldNew = mkCoercible loc oldty newty
            coOldVia =
              case mvia of  -- the via type is also eta reduced
                Just via -> [mkCoercible loc via newty]
                Nothing  -> []
            ctx = filter (not . null . freeTyVars . (:[])) (ctxOld : coOldNew : coOldVia)
        pure (eForall (clsIks ++ iks') $ addConstraints ctx $ tApp cls newty)
      Just (hdr, _) -> pure hdr
--  traceM ("newtypeDer: " ++ show (hdr, newty, viaty))
  ----
  let qiCls = getAppCon cls
      clsQual = qualOf qiCls
  ct <- gets classTable
  (ClassInfo _ _ _ mits _) <-
    case M.lookup qiCls ct of
      Nothing -> tcError loc $ "not a class " ++ showIdent qiCls
      Just x -> return x

  -- hdr looks like forall vs . ctx => C t1 ... tn
  let (_, newtys) = getApp $ dropContext $ dropForall hdr
      mkMethod (mi, amty) = do
        let (tvs, mty) =
              case amty of
                EForall _ xs (EApp (EApp _implies _Ca) t) -> (map idKindIdent xs, t)
                _ -> impossibleShow amty
            qvar t = EQVar t kType
            nty =
              if length tvs /= length newtys then error "mkMethod: arity" else
              case subst (zip tvs newtys) mty of
                EForall q vks t -> EForall q (map (\ (IdKind i _) -> IdKind i (EVar dummyIdent)) vks) $ qvar t
                t -> qvar t

            vty = qvar $ dropContext $ dropForall $ subst (zip tvs (init newtys ++ [viaty])) mty
            msign = Sign [mi] nty
            qmi = EQVar (EVar $ qualIdent clsQual mi) amty   -- Use a qualified name for the method
            body = Fcn mi [eEqn [] $ eAppI2 (mkBuiltin loc "coerce") (ETypeArg vty) qmi]
        return [msign, body]
  body <- concat <$> mapM mkMethod mits

--  traceM $ "newtypeDer: " ++ show (Instance hdr body [])
  return [Instance hdr body []]

dropForall :: EType -> EType
dropForall (EForall _ _ t) = dropForall t
dropForall t = t

dropContext :: EType -> EType
dropContext t =
  case getImplies t of
    Just (_, t') -> dropContext t'
    _ -> t

{-
freshForall :: EType -> EType
freshForall (EForall _ iks t) = EForall True (map (\ (IdKind i _) -> IdKind i (EVar dummyIdent)) iks) $ freshForall t
freshForall t = t
-}

-- Eta reduce as many of the variables as possible.
-- E.g. etaReduce [a,b] (T a b) = ([], T)
--      etaReduce [a,b] (T Int b) = ([a], T Int)
etaReduce :: [IdKind] -> EType -> ([IdKind], EType)
etaReduce ais = eta (reverse ais)
  where eta (IdKind i _ : is) (EApp t (EVar i')) | i == i' && i `notElem` freeTyVars [t] = eta is t
        eta is t = (reverse is, t)

anyclassDer :: StandM -> Int -> LHS -> EConstraint -> T [EDef]
anyclassDer mctx _ lhs cls = do
  hdr <- mkHdr mctx lhs [] cls
  return [Instance hdr [] []]
