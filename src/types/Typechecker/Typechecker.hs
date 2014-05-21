{-# LANGUAGE MultiParamTypeClasses, NamedFieldPuns #-}

{-|

Typechecks an "AST.AST" and produces the same tree, extended with
type information of every expression node. It throws an exception
with a meaningful error message if it fails.

-}

module Typechecker.Typechecker(typecheckEncoreProgram) where

-- Library dependencies
import Data.Maybe
import Data.List
import Control.Monad.Reader
import Control.Monad.Error

-- Module dependencies
import Identifiers
import AST.AST hiding (hasType, getType)
import qualified AST.AST as AST(hasType, getType)
import AST.PrettyPrinter
import Typechecker.Types
import Typechecker.Environment
import Typechecker.TypeError
--import qualified EAST.EAST as Ext

-- | The top-level type checking function
typecheckEncoreProgram :: Program -> Either TCError Program
typecheckEncoreProgram p = runReader (runErrorT (typecheck p)) (buildClassTable p)

-- | Convenience function for throwing an exception with the
-- current backtrace
tcError msg = do bt <- asks backtrace
                 throwError $ TCError (msg, bt)

-- | Convenience function for checking if a type is well-formed
wfType :: Type -> ErrorT TCError (Reader Environment) ()
wfType ty = do refType <- asks $ classLookup ty
               unless (isPrimitive ty || isJust refType) $ tcError $ "Unknown type '" ++ show ty ++ "'"

-- | The actual typechecking is done using a Reader monad wrapped
-- in an Error monad. The Reader monad lets us do lookups in the
-- "Environment", and the Error monad lets us throw a
-- "TCError" exception anywhere.
class Checkable a where
    -- | Returns the extended version of its argument
    typecheck :: a -> ErrorT TCError (Reader Environment) a

    -- | Returns the extended version of its argument if its type
    -- agrees with the second argument
    hasType   :: a -> Type -> ErrorT TCError (Reader Environment) a
    hasType _ _ = tcError "Typechecking not implemented for construct"

    -- | Convenience function for pushing and typechecking a
    -- component in one step.
    pushTypecheck :: Pushable a => a -> ErrorT TCError (Reader Environment) a
    pushTypecheck x = local (pushBT x) $ typecheck x

    pushHasType :: Pushable a => a -> Type -> ErrorT TCError (Reader Environment) a
    pushHasType x ty = local (pushBT x) $ hasType x ty

instance Checkable Program where
    typecheck (Program classes) = do eclasses <- mapM pushTypecheck classes
                                     return $ Program eclasses

instance Checkable ClassDecl where
    typecheck c@(Class {cname, fields, methods}) =
        do efields <- mapM pushTypecheck fields
           emethods <- mapM typecheckMethod methods
           unless distinctFieldNames $ tcError $ "Duplicate field names"
           unless distinctMethodNames $ tcError $ "Duplicate method names"
           return $ c {fields = efields, methods = emethods}
        where
          typecheckMethod m = local (extendEnvironment [(thisName, cname)]) $ pushTypecheck m
          distinctFieldNames = 
              nubBy (\f1 f2 -> (fname f1 == fname f2)) fields == fields
          distinctMethodNames = 
              nubBy (\m1 m2 -> (mname m1 == mname m2)) methods == methods

instance Checkable FieldDecl where
    typecheck f@(Field {ftype}) = do wfType ftype
                                     return $ setType ftype f

instance Checkable MethodDecl where
     typecheck m@(Method {mtype, mparams, mbody}) = 
         do wfType mtype
            mapM_ typecheckParam mparams
            eBody <- local addParams $ pushHasType mbody mtype
            return $ setType mtype m {mbody = eBody}
         where
           typecheckParam = (\p@(Param{ptype}) -> local (pushBT p) $ do {wfType ptype; return $ p})
           addParams = extendEnvironment $ map (\(Param {pname, ptype}) -> (pname, ptype)) mparams

instance Checkable Expr where
    hasType expr ty = do eExpr <- typecheck expr
                         unless (eExpr `AST.hasType` ty) $
                                tcError $ "Type mismatch. Expected type '" ++ show ty ++ "', got '" ++ show (AST.getType eExpr) ++ "'"
                         return eExpr

    typecheck skip@(Skip {}) = return $ setType voidType skip

    typecheck call@(Call {target, name, args}) = 
        do eTarget <- pushTypecheck target
           targetType <- return $ AST.getType eTarget
           when (isPrimitive targetType) $ 
                tcError $ "Cannot call method on expression '" ++ 
                          (show $ ppExpr target) ++ 
                          "' of primitive type '" ++ show targetType ++ "'"
           lookupResult <- asks $ methodLookup targetType name
           case lookupResult of
             Nothing -> tcError $ "No method '" ++ show name ++ "' in class '" ++ show targetType ++ "'"
             Just (returnType, params) -> 
                 do unless (length args == length params) $ 
                       tcError $ "Method '" ++ show name ++ "' of class '" ++ show targetType ++
                                 "' expects " ++ show (length params) ++ " arguments. Got " ++ show (length args)
                    eArgs <- zipWithM (\eArg (Param {ptype}) -> pushHasType eArg ptype) args params
                    return $ setType returnType call {target = eTarget, args = eArgs}

    typecheck let_@(Let {name, val, body}) = 
        do eVal <- pushTypecheck val
           eBody <- local (extendEnvironment [(name, AST.getType eVal)]) $ pushTypecheck body
           return $ setType (AST.getType eBody) let_ {val = eVal, body = eBody}

    typecheck seq@(Seq {eseq}) = 
        do eEseq <- mapM pushTypecheck eseq 
           seqType <- return $ AST.getType (last eEseq)
           return $ setType seqType seq {eseq = eEseq}

    typecheck ifThenElse@(IfThenElse {cond, thn, els}) = 
        do eCond <- pushHasType cond boolType
           eThn <- pushTypecheck thn
           thnType <- return $ AST.getType eThn
           eEls <- pushHasType els thnType
           return $ setType thnType ifThenElse {cond = eCond, thn = eThn, els = eEls}

    typecheck while@(While {cond, body}) = 
        do eCond <- pushHasType cond boolType
           eBody <- pushTypecheck body
           return $ setType (AST.getType eBody) while {cond = eCond, body = eBody}

    typecheck get@(Get {}) = mzero

    typecheck fAcc@(FieldAccess {target, name}) = 
        do eTarget <- pushTypecheck target
           pathType <- return $ AST.getType eTarget
           when (isPrimitive pathType) $ 
                tcError $ "Cannot read field of expression '" ++ 
                          (show $ ppExpr target) ++ "' of primitive type '" ++ show pathType ++ "'"
           fType <- asks $ fieldLookup pathType name
           case fType of
             Just ty -> return $ setType ty fAcc {target = eTarget}
             Nothing -> tcError $ "No field '" ++ show name ++ "' in class '" ++ show pathType ++ "'"                                                         

    typecheck assign@(Assign {lhs, rhs}) = 
        do eLhs <- pushTypecheck lhs
           eRhs <- pushHasType rhs (AST.getType eLhs)
           return $ setType voidType assign {lhs = eLhs, rhs = eRhs}

    typecheck var@(VarAccess {name}) = 
        do varType <- asks $ varLookup name
           case varType of
             Just ty -> return $ setType ty var
             Nothing -> tcError $ "Unbound variable '" ++ show name ++ "'"

    typecheck null@Null {} = return $ setType nullType null

    typecheck true@BTrue {} = return $ setType boolType true 

    typecheck false@BFalse {} = return $ setType boolType false 

    typecheck new@(New {ty}) = 
        do wfType ty
           return $ setType ty new

    typecheck print@(Print {val}) = 
        do eVal <- pushTypecheck val
           return $ setType voidType print {val = eVal}

    typecheck stringLit@(StringLiteral {}) = return $ setType stringType stringLit

    typecheck intLit@(IntLiteral {}) = return $ setType intType intLit

    typecheck binop@(Binop {op, loper, roper})
        | op `elem` cmpOps = 
            do eLoper <- pushHasType loper intType
               eRoper <- pushHasType roper intType
               return $ setType boolType binop {loper = eLoper, roper = eRoper}
        | op `elem` eqOps =
            do eLoper <- pushTypecheck loper
               eRoper <- pushHasType roper (AST.getType eLoper)
               return $ setType boolType binop {loper = eLoper, roper = eRoper}
        | op `elem` arithOps = 
            do eLoper <- pushHasType loper intType
               eRoper <- pushHasType roper intType
               return $ setType intType binop {loper = eLoper, roper = eRoper}
        | otherwise = tcError $ "Undefined binary operator '" ++ show op ++ "'"
        where
          cmpOps   = [Identifiers.LT, Identifiers.GT]
          eqOps    = [Identifiers.EQ, NEQ]
          arithOps = [PLUS, MINUS, TIMES, DIV]

instance Checkable LVal where
    hasType lval ty = do eLVal <- typecheck lval
                         unless (eLVal `AST.hasType` ty) $ 
                                tcError $ "Type mismatch. Expected type '" ++ show ty ++ "', got '" ++ show (AST.getType eLVal) ++ "'"
                         return eLVal

    typecheck lval@(LVal {lname}) = 
        do varType <- asks (varLookup lname)
           case varType of
             Just ty -> return $ setType ty lval
             Nothing -> tcError $ "Unbound variable '" ++ show lname ++ "'"
    typecheck lval@(LField {ltarget, lname}) = 
        do eTarget <- typecheck ltarget
           pathType <- return $ AST.getType eTarget
           when (isPrimitive pathType) $ 
                tcError $ "Cannot read field of expression '" ++ (show $ ppExpr ltarget) ++ 
                          "' of primitive type '" ++ show pathType ++ "'"
           fType <- asks $ fieldLookup (AST.getType eTarget) lname
           case fType of
             Just ty -> return $ setType ty lval {ltarget = eTarget}
             Nothing -> tcError $ "No field '" ++ show lname ++ "' in class '" ++ show pathType ++ "'"