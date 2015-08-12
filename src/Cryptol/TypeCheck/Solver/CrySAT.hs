-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Safe #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternGuards #-}
module Cryptol.TypeCheck.Solver.CrySAT
  ( withScope, withSolver
  , assumeProps, simplifyProps, getModel
  , check
  , Solver, logger
  , DefinedProp(..)
  , debugBlock
  , DebugLog(..)
  , knownDefined
  , minimizeContradictionSimpDef
  ) where

import qualified Cryptol.TypeCheck.AST as Cry
import           Cryptol.TypeCheck.InferTypes(Goal(..), SolverConfig(..))
import qualified Cryptol.TypeCheck.Subst as Cry

import           Cryptol.TypeCheck.Solver.Numeric.AST
import           Cryptol.TypeCheck.Solver.Numeric.ImportExport
import           Cryptol.TypeCheck.Solver.Numeric.Defined
import           Cryptol.TypeCheck.Solver.Numeric.Simplify
import           Cryptol.TypeCheck.Solver.Numeric.NonLin
import           Cryptol.TypeCheck.Solver.Numeric.SMT
import           Cryptol.Utils.PP -- ( Doc )
import           Cryptol.Utils.Panic ( panic )

import           MonadLib
import           Data.Maybe ( mapMaybe, fromMaybe )
import qualified Data.Map as Map
import           Data.Foldable ( any, all )
import qualified Data.Set as Set
import           Data.IORef ( IORef, newIORef, readIORef, modifyIORef',
                              atomicModifyIORef' )
import           Prelude hiding (any,all)

import qualified SimpleSMT as SMT


-- | We use this to remember what we simplified
newtype SimpProp = SimpProp { unSimpProp :: Prop }

simpProp :: Prop -> SimpProp
simpProp p = SimpProp (crySimplify p)


-- | 'dpSimpProp' and 'dpSimpExprProp' should be logically equivalent,
-- to each other, and to whatever 'a' represents (usually 'a' is a 'Goal').
data DefinedProp a = DefinedProp
  { dpData         :: a
    -- ^ Optional data to associate with prop.
    -- Often, the original `Goal` from which the prop was extracted.

  , dpSimpProp     :: SimpProp
    {- ^ Fully simplified: may mention ORs, and named non-linear terms.
    These are what we send to the prover, and we don't attempt to
    convert them back into Cryptol types. -}

  , dpSimpExprProp :: Prop
    {- ^ A version of the proposition where just the expression terms
    have been simplified.  These should not contain ORs or named non-linear
    terms because we want to import them back into Crytpol types. -}
  }

knownDefined :: (a,Prop) -> DefinedProp a
knownDefined (a,p) = DefinedProp
  { dpData = a, dpSimpProp = simpProp p, dpSimpExprProp = p }


instance HasVars SimpProp where
  apSubst su (SimpProp p) = do p1 <- apSubst su p
                               let p2 = crySimplify p1
                               guard (p1 /= p2)
                               return (SimpProp p2)




-- | Simplify a bunch of well-defined properties.
--  * Eliminates properties that are implied by the rest.
--  * Does not modify the set of assumptions.
simplifyProps :: Solver -> [DefinedProp a] -> IO [a]
simplifyProps s props =
  debugBlock s "Simplifying properties" $
  withScope s (go [] (eliminateSimpleGEQ props))
  where
  go survived [] = return survived

  go survived (DefinedProp { dpSimpProp = SimpProp PTrue } : more) =
                                                          go survived more

  go survived (p : more) =
    case dpSimpProp p of
      SimpProp PTrue -> go survived more
      SimpProp p' ->
        do proved <- withScope s $ do mapM_ (assert s . dpSimpProp) more
                                      prove s p'
           if proved
             then go survived more
             else do assert s (SimpProp p')
                     go (dpData p : survived) more


{- | Simplify easy less-than-or-equal-to and equal-to goals.
Those are common with long lists of literals, so we have special handling
for them.  In particular:

  * Reduce goals of the form @(a >= k1, a >= k2, a >= k3, ...)@ to
   @a >= max (k1, k2, k3, ...)@, when all the k's are constant.

  * Eliminate goals of the form @ki >= k2@, when @k2@ is leq than @k1@.

  * Eliminate goals of the form @a >= 0@.

NOTE:  This assumes that the goals are well-defined.
-}
eliminateSimpleGEQ :: [DefinedProp a] -> [DefinedProp a]
eliminateSimpleGEQ = go Map.empty []
  where

  go geqs other (g : rest) =
    case dpSimpExprProp g of
      K a :== K b
        | a == b -> go geqs other rest

      _ :>= K (Nat 0) ->
          go geqs  other rest

      K (Nat k1) :>= K (Nat k2)
        | k1 >= k2 -> go geqs other rest

      Var v :>= K (Nat k2) ->
        go (addUpperBound v (k2,g) geqs) other rest

      _ -> go geqs (g:other) rest

  go geqs other [] = [ g | (_,g) <- Map.elems geqs ] ++ other

  -- add in a possible upper bound for var
  addUpperBound var g = Map.insertWith cmp var g
    where
    cmp a b | fst a > fst b = a
            | otherwise     = b





-- | Add the given constraints as assumptions.
--  * We assume that the constraints are well-defined.
--  * Modifies the set of assumptions.
assumeProps :: Solver -> [Cry.Prop] -> IO [SimpProp]
assumeProps s props =
  do let ps = mapMaybe exportProp props
     let simpProps = map simpProp (map cryDefinedProp ps ++ ps)
     mapM_ (assert s) simpProps
     return simpProps
  -- XXX: Instead of asserting one at a time, perhaps we should
  -- assert a conjunction.  That way, we could simplify the whole thing
  -- in one go, and would avoid having to assert 'true' many times.




-- | Given a list of propositions that together lead to a contradiction,
-- find a sub-set that still leads to a contradiction (but is smaller).
minimizeContradictionSimpDef :: Solver -> [DefinedProp a] -> IO [a]
minimizeContradictionSimpDef s ps = start [] ps
  where
  start bad todo =
    do res <- SMT.check (solver s)
       case res of
         SMT.Unsat -> return (map dpData bad)
         _         -> do solPush s
                         go bad [] todo

  go _ _ [] = panic "minimizeContradiction"
               $ ("No contradiction" : map (show . ppProp . dpSimpExprProp) ps)
  go bad prev (d : more) =
    do assert s (dpSimpProp d)
       res <- SMT.check (solver s)
       case res of
         SMT.Unsat -> do solPop s
                         assert s (dpSimpProp d)
                         start (d : bad) prev
         _ -> go bad (d : prev) more



{- | Attempt to find a substituion that, when applied, makes all of the
given properties hold. -}
getModel :: Solver -> [Cry.Prop] -> IO (Maybe Cry.Subst)
getModel s props = withScope s $
  do ps  <- assumeProps s props
     res <- SMT.check (solver s)
     let vars = Set.toList $ Set.unions $ map (cryPropFVS . unSimpProp) ps

     case res of
       SMT.Sat ->
          do vs <- getVals (solver s) vars
             -- This is guaranteed to be a model only for the *linear*
             -- properties, so now we check if it works for the rest too.

             let su1  = fmap K vs
                 ps1  = [ fromMaybe p (apSubst su1 p) | SimpProp p <- ps ]
                 ok p = case crySimplify p of
                          PTrue -> True
                          _     -> False

                 su2 = Cry.listSubst
                          [ (x, numTy v) | (UserName x, v) <- Map.toList vs ]

             return (guard (all ok ps1) >> return su2)


       _ -> return Nothing


  where
  numTy Inf     = Cry.tInf
  numTy (Nat k) = Cry.tNum k

--------------------------------------------------------------------------------


-- | An SMT solver, and some info about declared variables.
data Solver = Solver
  { solver    :: SMT.Solver
    -- ^ The actual solver

  , declared  :: IORef VarInfo
    -- ^ Information about declared variables, and assumptions in scope.

  , logger    :: SMT.Logger
    -- ^ For debugging
  }


-- | Keeps track of declared variables and non-linear terms.
data VarInfo = VarInfo
  { curScope    :: Scope
  , otherScopes :: [Scope]
  } deriving Show

data Scope = Scope
  { scopeNames    :: [Name]
    -- ^ Variables declared in this scope (not counting the ones from
    -- previous scopes).

  , scopeNonLinS  :: NonLinS
    {- ^ These are the non-linear terms mentioned in the assertions
    that are currently asserted (including ones from previous scopes). -}

  } deriving Show

scopeEmpty :: Scope
scopeEmpty = Scope { scopeNames = [], scopeNonLinS = initialNonLinS }

scopeElem :: Name -> Scope -> Bool
scopeElem x Scope { .. } = x `elem` scopeNames

scopeInsert :: Name -> Scope -> Scope
scopeInsert x Scope { .. } = Scope { scopeNames = x : scopeNames, .. }


-- | Given a *simplified* prop, separate linear and non-linear parts
-- and return the linear ones.
scopeAssert :: SimpProp -> Scope -> ([SimpProp],Scope)
scopeAssert (SimpProp p) Scope { .. } =
  let (ps1,s1) = nonLinProp scopeNonLinS p
  in (map SimpProp ps1, Scope { scopeNonLinS = s1, ..  })


-- | No scopes.
viEmpty :: VarInfo
viEmpty = VarInfo { curScope = scopeEmpty, otherScopes = [] }

-- | Check if a name is any of the scopes.
viElem :: Name -> VarInfo -> Bool
viElem x VarInfo { .. } = any (x `scopeElem`) (curScope : otherScopes)

-- | Add a name to a scope.
viInsert :: Name -> VarInfo -> VarInfo
viInsert x VarInfo { .. } = VarInfo { curScope = scopeInsert x curScope, .. }

-- | Add an assertion to the current scope. Returns the linear part.
viAssert :: SimpProp -> VarInfo -> (VarInfo, [SimpProp])
viAssert p VarInfo { .. } = ( VarInfo { curScope = s1, .. }, p1)
  where (p1, s1) = scopeAssert p curScope

-- | Enter a scope.
viPush :: VarInfo -> VarInfo
viPush VarInfo { .. } =
  VarInfo { curScope = scopeEmpty { scopeNonLinS = scopeNonLinS curScope }
          , otherScopes = curScope : otherScopes
          }

-- | Exit a scope.
viPop :: VarInfo -> VarInfo
viPop VarInfo { .. } = case otherScopes of
                         c : cs -> VarInfo { curScope = c, otherScopes = cs }
                         _ -> panic "viPop" ["no more scopes"]


-- | All declared names, that have not been "marked".
-- These are the variables whose values we are interested in.
viUnmarkedNames :: VarInfo -> [ Name ]
viUnmarkedNames VarInfo { .. } = concatMap scopeNames scopes
  where scopes      = curScope : otherScopes



-- | All known non-linear terms.
getNLSubst :: Solver -> IO Subst
getNLSubst Solver { .. } =
  do VarInfo { .. } <- readIORef declared
     return $ nonLinSubst $ scopeNonLinS curScope

-- | Execute a computation with a fresh solver instance.
withSolver :: SolverConfig -> (Solver -> IO a) -> IO a
withSolver SolverConfig { .. } k =
  do logger <- if solverVerbose > 0 then SMT.newLogger 0 else return quietLogger


     let smtDbg = if solverVerbose > 1 then Just logger else Nothing
     solver <- SMT.newSolver solverPath solverArgs smtDbg
     _ <- SMT.setOptionMaybe solver ":global-decls" "false"
     SMT.setLogic solver "QF_LIA"
     declared <- newIORef viEmpty
     a <- k Solver { .. }
     _ <- SMT.stop solver

     return a

  where
  quietLogger = SMT.Logger { SMT.logMessage = \_ -> return ()
                           , SMT.logLevel   = return 0
                           , SMT.logSetLevel= \_ -> return ()
                           , SMT.logTab     = return ()
                           , SMT.logUntab   = return ()
                           }

solPush :: Solver -> IO ()
solPush Solver { .. } =
  do SMT.push solver
     SMT.logTab logger
     modifyIORef' declared viPush

solPop :: Solver -> IO ()
solPop Solver { .. } =
  do modifyIORef' declared viPop
     SMT.logUntab logger
     SMT.pop solver

-- | Execute a computation in a new solver scope.
withScope :: Solver -> IO a -> IO a
withScope s k =
  do solPush s
     a <- k
     solPop s
     return a

-- | Declare a variable.
declareVar :: Solver -> Name -> IO ()
declareVar s@Solver { .. } a =
  do done <- fmap (a `viElem`) (readIORef declared)
     unless done $
       do e  <- SMT.declare solver (smtName a)    SMT.tInt
          let fin_a = smtFinName a
          fin <- SMT.declare solver fin_a SMT.tBool
          SMT.assert solver (SMT.geq e (SMT.int 0))

          nlSu <- getNLSubst s
          modifyIORef' declared (viInsert a)
          case Map.lookup a nlSu of
            Nothing -> return ()
            Just e'  ->
              do let finDef = crySimplify (Fin e')
                 mapM_ (declareVar s) (Set.toList (cryPropFVS finDef))
                 SMT.assert solver $
                    SMT.eq fin (ifPropToSmtLib (desugarProp finDef))



-- | Add an assertion to the current context.
-- INVARIANT: Assertion is simplified.
assert :: Solver -> SimpProp -> IO ()
assert _ (SimpProp PTrue) = return ()
assert s@Solver { .. } p@(SimpProp p0) =
  do debugLog s ("Assuming: " ++ show (ppProp p0))
     ps1' <- atomicModifyIORef' declared (viAssert p)
     let ps1 = map unSimpProp ps1'
         vs  = Set.toList $ Set.unions $ map cryPropFVS ps1
     mapM_ (declareVar s) vs
     mapM_ (SMT.assert solver . ifPropToSmtLib . desugarProp) ps1


-- | Try to prove a property.  The result is 'True' when we are sure that
-- the property holds, and 'False' otherwise.  In other words, getting `False`
-- *does not* mean that the proposition does not hold.
prove :: Solver -> Prop -> IO Bool
prove _ PTrue = return True
prove s@(Solver { .. }) p =
  debugBlock s ("Proving: " ++ show (ppProp p)) $
  withScope s $
  do assert s (simpProp (Not p))
     res <- SMT.check solver
     case res of
       SMT.Unsat   -> debugLog s "Proved" >> return True
       SMT.Unknown -> debugLog s "Not proved" >> return False -- We are not sure
       SMT.Sat     -> debugLog s "Not proved" >> return False
        -- XXX: If the answer is Sat, it is possible that this is a
        -- a fake example, as we need to evaluate the nonLinear constraints.
        -- If they are all satisfied, then we have a genuine counter example.
        -- Otherwise, we could look for another one...


{- | Check if the current set of assumptions is satisfiable, and find
some facts that must hold in any models of the current assumptions.

Returns `Nothing` if the currently asserted constraints are known to
be unsatisfiable.

Returns `Just (su, sub-goals)` is the current set is satisfiable.
  * The `su` is a substitution that may be applied to the current constraint
    set without loosing generality.
  * The `sub-goals` are additional constraints that must hold if the
    constraint set is to be satisfiable.
-}
check :: Solver -> IO (Maybe (Subst, [Prop]))
check s@Solver { .. } =
  do res <- SMT.check solver
     case res of

       SMT.Unsat   ->
        do debugLog s "Not satisfiable"
           return Nothing

       SMT.Unknown ->
        do debugLog s "Unknown"
           return (Just (Map.empty, []))

       SMT.Sat     ->
        do debugLog s "Satisfiable"
           (impMap,sideConds) <- debugBlock s "Computing improvements"
                                     (getImpSubst s)
           return (Just (impMap, sideConds))



{- | Assuming that we are in a satisfiable state, try to compute an
improving substitution.  We also return additional constraints that must
hold for the currently asserted propositions to hold.
-}
getImpSubst :: Solver -> IO (Subst,[Prop])
getImpSubst s@Solver { .. } =
  do names <- viUnmarkedNames `fmap` readIORef declared
     m     <- getVals solver names
     (impSu,sideConditions) <- cryImproveModel solver logger m

     nlSu <- getNLSubst s

     let isNonLinName (SysName {})  = True
         isNonLinName (UserName {}) = False

         (nlFacts, vFacts) = Map.partitionWithKey (\k _ -> isNonLinName k) impSu

         (vV, vNL)  = Map.partition noNLVars vFacts

         nlSu1  = fmap (doAppSubst vV) nlSu

         (vNL_su,vNL_eqs) = Map.partitionWithKey goodDef
                          $ fmap (doAppSubst nlSu1) vNL

         nlSu2 = fmap (doAppSubst vNL_su) nlSu1
         nlLkp x = case Map.lookup x nlSu2 of
                     Just e  -> e
                     Nothing -> panic "getImpSubst"
                                [ "Missing NL variable:", show x ]

         allSides =
           [ Var a   :== e                  | (a,e) <- Map.toList vNL_eqs ] ++
           [ nlLkp x :== doAppSubst nlSu2 e | (x,e) <- Map.toList nlFacts ] ++
           [ doAppSubst nlSu2 si            | si    <- sideConditions ]

         theImpSu = composeSubst vNL_su vV

     debugBlock s "Improvments" $
       do debugBlock s "substitution" $
            mapM_ (debugLog s . dump) (Map.toList theImpSu)
          debugBlock s "side-conditions" $ debugLog s allSides


     return (theImpSu, allSides)


  where
  goodDef k e = not (k `Set.member` cryExprFVS e)

  isNLVar (SysName _) = True
  isNLVar _           = False

  noNLVars e = all (not . isNLVar) (cryExprFVS e)

  dump (x,e) = show (ppProp (Var x :== e))

--------------------------------------------------------------------------------

debugBlock :: Solver -> String -> IO a -> IO a
debugBlock s@Solver { .. } name m =
  do debugLog s name
     SMT.logTab logger
     a <- m
     SMT.logUntab logger
     return a

class DebugLog t where
  debugLog :: Solver -> t -> IO ()

  debugLogList :: Solver -> [t] -> IO ()
  debugLogList s ts = case ts of
                        [] -> debugLog s "(none)"
                        _  -> mapM_ (debugLog s) ts

instance DebugLog Char where
  debugLog s x     = SMT.logMessage (logger s) (show x)
  debugLogList s x = SMT.logMessage (logger s) x

instance DebugLog a => DebugLog [a] where
  debugLog = debugLogList

instance DebugLog a => DebugLog (Maybe a) where
  debugLog s x = case x of
                   Nothing -> debugLog s "(nothing)"
                   Just a  -> debugLog s a

instance DebugLog Doc where
  debugLog s x = debugLog s (show x)

instance DebugLog Cry.Type where
  debugLog s x = debugLog s (pp x)

instance DebugLog Goal where
  debugLog s x = debugLog s (goal x)

instance DebugLog Cry.Subst where
  debugLog s x = debugLog s (pp x)

instance DebugLog Prop where
  debugLog s x = debugLog s (ppProp x)



