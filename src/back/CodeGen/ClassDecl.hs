{-# LANGUAGE MultiParamTypeClasses, TypeSynonymInstances, FlexibleInstances, GADTs, NamedFieldPuns #-}

{-| Translate a @ClassDecl@ (see "AST") to its @CCode@ (see
"CCode.Main") equivalent.

 -}

module CodeGen.ClassDecl () where

import CodeGen.Typeclasses
import CodeGen.CCodeNames
import CodeGen.MethodDecl
import CodeGen.Type
import qualified CodeGen.Context as Ctx

import CCode.Main
import CCode.PrettyCCode

import Data.List

import qualified AST.AST as A
import qualified Identifiers as ID
import qualified Types as Ty

import Control.Monad.Reader hiding (void)

instance Translatable A.ClassDecl (CCode FIN) where
  translate cdecl
      | A.isActive cdecl = translateActiveClass cdecl
      | otherwise        = translatePassiveClass cdecl

-- | Translates an active class into its C representation. Note
-- that there are additional declarations in the file generated by
-- "CodeGen.Header"
translateActiveClass cdecl@(A.Class{A.cname, A.fields, A.methods}) =
    Program $ Concat $
      (LocalInclude "header.h") :
      [type_struct] ++
      [tracefun_decl cdecl] ++
      method_impls ++
      [dispatchfun_decl] ++
      [pony_type_t_decl cname]
    where
      type_struct :: CCode Toplevel
      type_struct = StructDecl (AsType $ class_type_name cname) $
                     ((encore_actor_t, Var "_enc__actor") :
                         zip
                         (map (translate  . A.ftype) fields)
                         (map (Var . show . A.fname) fields))

      method_impls = map method_impl methods
          where
            method_impl mdecl = translate mdecl cdecl

      dispatchfun_decl :: CCode Toplevel
      dispatchfun_decl =
          (Function (Static void) (class_dispatch_name cname)
           ([(Ptr . Typ $ "pony_actor_t", Var "_a"),
             (Ptr . Typ $ "pony_msg_t", Var "_m")])
           (Seq [Assign (Decl (Ptr . AsType $ class_type_name cname, Var "this"))
                        (Var "_a"),
                 (Switch (Var "_m" `Arrow` Nam "id")
                  ((Nam "_ENC__MSG_RESUME_SUSPEND", fut_resume_suspend_instr) :
                   (Nam "_ENC__MSG_RESUME_AWAIT", fut_resume_await_instr) :
                   (Nam "_ENC__MSG_RUN_CLOSURE", fut_run_closure_instr) :
                   (if (A.isMainClass cdecl)
                    then pony_main_clause : (method_clauses $ filter ((/= ID.Name "main") . A.mname) methods)
                    else method_clauses $ methods
                   ))
                  (Statement $ Call (Nam "printf") [String "error, got invalid id: %zd", AsExpr $ Var "id"]))]))
           where
             fut_resume_instr =
                 Seq
                   [Assign (Decl (Ptr $ Typ "future_t", Var "fut"))
                           ((ArrAcc 0 (Var "argv")) `Dot` (Nam "p")),
                    Statement $ Call (Nam "future_resume") [Var "fut"]]

             fut_resume_suspend_instr =
                 Seq
                   [Assign (Decl (Ptr $ Typ "void", Var "s"))
                           ((ArrAcc 0 (Var "argv")) `Dot` (Nam "p")),
                    Statement $ Call (Nam "future_suspend_resume") [Var "s"]]

             fut_resume_await_instr =
                 Seq
                   [Statement $ Call (Nam "future_await_resume") [Var "argv"]]

             fut_run_closure_instr =
                 Seq
                   [Assign (Decl (closure, Var "closure"))
                           ((ArrAcc 0 (Var "argv")) `Dot` (Nam "p")),
                    Assign (Decl (Typ "value_t", Var "closure_arguments[]"))
                           (Record [UnionInst (Nam "p") (ArrAcc 1 (Var "argv") `Dot` (Nam "p"))]),
                    Statement $ Call (Nam "closure_call") [Var "closure", Var "closure_arguments"]]

             pony_main_clause =
                 (Nam "PONY_MAIN",
                  Seq $ [Statement $ Call ((method_impl_name (Ty.refType "Main") (ID.Name "main")))
                                          [AsExpr $ Var "p",
                                           AsExpr $ (ArrAcc 0 (Var "argv")) `Dot` (Nam "i"),
                                           Cast (Ptr $ Ptr char) $ (ArrAcc 1 (Var "argv")) `Dot` (Nam "p")]])

             method_clauses :: [A.MethodDecl] -> [(CCode Name, CCode Stat)]
             method_clauses = concatMap method_clause

             method_clause m = (mthd_dispatch_clause m) :
                               if not (A.isStreamMethod m)
                               then [one_way_send_dispatch_clause m]
                               else []

             mthd_dispatch_clause mdecl@(A.Method{A.mname, A.mparams, A.mtype})  =
                (method_msg_name cname mname,
                 Seq [Assign (Decl (Ptr $ Typ "future_t", Var "fut"))
                      ((ArrAcc 0 ((Var "argv"))) `Dot` (Nam "p")),
                      Statement $ Call (Nam "future_fulfil")
                                       [AsExpr $ Var "fut",
                                        Cast (Ptr void)
                                             (Call (method_impl_name cname mname)
                                              ((AsExpr . Var $ "p") :
                                               (paramdecls_to_argv 1 $ mparams)))]])
             mthd_dispatch_clause mdecl@(A.StreamMethod{A.mname, A.mparams})  =
                (method_msg_name cname mname,
                 Seq [Assign (Decl (Ptr $ Typ "future_t", Var "fut"))
                      ((ArrAcc 0 ((Var "argv"))) `Dot` (Nam "p")),
                      Statement $ Call (method_impl_name cname mname)
                                        ((AsExpr . Var $ "p") :
                                         (AsExpr . Var $ "fut") :
                                         (paramdecls_to_argv 1 $ mparams))])

             one_way_send_dispatch_clause mdecl@A.Method{A.mname, A.mparams} =
                (one_way_send_msg_name cname mname,
                 (Statement $
                  Call (method_impl_name cname mname)
                       ((AsExpr . Var $ "p") : (paramdecls_to_argv 0 $ mparams))))

             paramdecls_to_argv :: Int -> [A.ParamDecl] -> [CCode Expr]
             paramdecls_to_argv start_idx = zipWith paramdecl_to_argv [start_idx..]

             paramdecl_to_argv argv_idx (A.Param {A.ptype}) =
                let arg_cell = ArrAcc argv_idx (Var "argv")
                in
                  AsExpr $
                  arg_cell `Dot`
                      (case translate ptype of
                         (Typ "int64_t") -> (Nam "i")
                         (Typ "double")  -> (Nam "d")
                         (Ptr _)         -> (Nam "p")
                         other           ->
                             error $ "ClassDecl.hs: paramdecl_to_argv not implemented for "++show ptype)

-- | Translates a passive class into its C representation. Note
-- that there are additional declarations (including the data
-- struct for instance variables) in the file generated by
-- "CodeGen.Header"
translatePassiveClass cdecl@(A.Class{A.cname, A.fields, A.methods}) =
    Program $ Concat $
      (LocalInclude "header.h") :
      [tracefun_decl cdecl] ++
      method_impls ++
      [pony_type_t_decl cname]

    where
      method_impls = map method_decl methods
          where
            method_decl mdecl = translate mdecl cdecl

tracefun_decl :: A.ClassDecl -> CCode Toplevel
tracefun_decl A.Class{A.cname, A.fields, A.methods} = 
    case find ((== Ty.getId cname ++ "_trace") . show . A.mname) methods of
      Just mdecl@(A.Method{A.mbody, A.mname}) ->
          Function void (class_trace_fn_name cname) 
                   [(Ptr void, Var "p")]
                   (Statement $ Call (method_impl_name cname mname)
                                [Var "p"])
      Nothing -> 
          Function void (class_trace_fn_name cname) 
                   [(Ptr void, Var "p")]
                   (Seq $ 
                    (Assign (Decl (Ptr . AsType $ class_type_name cname, Var "this"))
                            (Var "p")) :
                     map (Statement . trace_field) fields)
    where
      trace_field A.Field {A.ftype, A.fname}
          | Ty.isActiveRefType ftype =
              Call (Nam "pony_traceactor") [get_field fname]
          | Ty.isPassiveRefType ftype =
              Call (Nam "pony_traceobject") 
                   [get_field fname, AsLval $ class_trace_fn_name ftype]
          | otherwise =
              Embed $ "/* Not tracing field '" ++ show fname ++ "' */"

      get_field f = 
          (Var "this") `Arrow` (Nam $ show f)


pony_type_t_decl cname =
    (AssignTL
     (Decl (Typ "pony_type_t", AsLval $ runtime_type_name cname))
           (Record [AsExpr . AsLval . Nam $ ("ID_"++(Ty.getId cname)),
                    Call (Nam "sizeof") [AsLval $ class_type_name cname],
                    AsExpr . AsLval $ (class_trace_fn_name cname),
                    Null,
                    Null,           
                    AsExpr . AsLval $ class_dispatch_name cname,
                    Null]))
