open Big_int
open Num
open Util

(* Region: Locations *)

(** Base path, relative path, line (1-based), column (1-based) *)
type srcpos = (string * int * int) (* ?srcpos *)

(** A range of source code: start position, end position *)
type loc0 = (srcpos * srcpos) (* ?loc *)

let dummy_srcpos = ("<nowhere>", 0, 0)
let dummy_loc0 = (dummy_srcpos, dummy_srcpos)

(*
Visual Studio format:
C:\ddd\sss.xyz(123): error VF0001: blah
C:\ddd\sss.xyz(123,456): error VF0001: blah
C:\ddd\sss.xyz(123,456-789): error VF0001: blah
C:\ddd\sss.xyz(123,456-789,123): error VF0001: blah
GNU format:
C:\ddd\sss.xyz:123: error VF0001: blah
C:\ddd\sss.xyz:123.456: error VF0001: blah
C:\ddd\sss.xyz:123.456-789: error VF0001: blah
C:\ddd\sss.xyz:123.456-789.123: error VF0001: blah
See
http://blogs.msdn.com/msbuild/archive/2006/11/03/msbuild-visual-studio-aware-error-messages-and-message-formats.aspx
and
http://www.gnu.org/prep/standards/standards.html#Errors
*)

let string_of_srcpos (p,l,c) = p ^ "(" ^ string_of_int l ^ "," ^ string_of_int c ^ ")"

let string_of_loc0 ((p1, l1, c1), (p2, l2, c2)) =
  p1 ^ "(" ^ string_of_int l1 ^ "," ^ string_of_int c1 ^
  if p1 = p2 then
    if l1 = l2 then
      if c1 = c2 then
        ")"
      else
        "-" ^ string_of_int c2 ^ ")"
    else
      "-" ^ string_of_int l2 ^ "," ^ string_of_int c2 ^ ")"
  else
    ")-" ^ p2 ^ "(" ^ string_of_int l2 ^ "," ^ string_of_int c2 ^ ")"

(* A token provenance. Complex because of the C preprocessor. *)

type loc =
  Lexed of loc0
| DummyLoc
| MacroExpansion of
    loc (* Call site *)
    * loc (* Body token *)
| MacroParamExpansion of
    loc (* Parameter occurrence being expanded *)
    * loc (* Argument token *)
 
let dummy_loc = DummyLoc

let rec root_caller_token l =
  match l with
    Lexed l -> l
  | MacroExpansion (lcall, _) -> root_caller_token lcall
  | MacroParamExpansion (lparam, _) -> root_caller_token lparam

let rec string_of_loc l =
  match l with
    Lexed l0 -> string_of_loc0 l0
  | DummyLoc -> "<dummy location>"
  | MacroExpansion (lcall, lbody) -> Printf.sprintf "%s (body token %s)" (string_of_loc lcall) (string_of_loc lbody)
  | MacroParamExpansion (lparam, larg) -> Printf.sprintf "%s (argument token %s)" (string_of_loc lparam) (string_of_loc larg)

(* Some types for dealing with constants *)

type constant_value = (* ?constant_value *)
  IntConst of big_int
| BoolConst of bool
| StringConst of string
| NullConst

exception NotAConstant

(* Region: ASTs *)

(* Because using "True" and "False" for everything results in unreadable sourcecode *)
type inductiveness = (* ? inductiveness *)
  | Inductiveness_Inductive (* prefixing to avoid nameclash with "Inductive" *)
  | Inductiveness_CoInductive

let string_of_inductiveness inductiveness =
  match inductiveness with
  | Inductiveness_Inductive -> "inductive"
  | Inductiveness_CoInductive -> "coinductive"
  
type signedness = Signed | Unsigned

type int_rank =
  LitRank of int  (* The size of an integer of rank k is 2^k bytes. *)
| IntRank
| LongRank
| PtrRank

type type_ = (* ?type_ *)
    Bool
  | Void
  | Int of signedness * int_rank (*rank*)  (* The size of Int (_, k) is 2^k bytes. For example: uint8 is denoted as Int (Unsigned, 0). *)
  | RealType  (* Mathematical real numbers. Used for fractional permission coefficients. Also used for reasoning about floating-point code. *)
  | Float
  | Double
  | LongDouble
  | StructType of string
  | UnionType of string
  | PtrType of type_
  | FuncType of string   (* The name of a typedef whose body is a C function type. *)
  | InductiveType of string * type_ list
  | PredType of string list * type_ list * int option * inductiveness (* if None, not necessarily precise; if Some n, precise with n input parameters *)
  | PureFuncType of type_ * type_  (* Curried *)
  | ObjType of string * type_ list (* type arguments *)
  | ArrayType of type_
  | StaticArrayType of type_ * int (* for array declarations in C *)
  | BoxIdType (* box type, for shared boxes *)
  | HandleIdType (* handle type, for shared boxes *)
  | AnyType (* supertype of all inductive datatypes; useful in combination with predicate families *)
  | RealTypeParam of string (* a reference to a type parameter declared in the enclosing Real code *)
  | InferredRealType of string
  | GhostTypeParam of string (* a reference to a type parameter declared in the ghost code *)
  | InferredType of < > * inferred_type_state ref (* inferred type, is unified during type checking. '< >' is the type of objects with no methods. This hack is used to prevent types from incorrectly comparing equal, as in InferredType (ref Unconstrained) = InferredType (ref Unconstrained). Yes, ref Unconstrained = ref Unconstrained. But object end <> object end. *)
  | ClassOrInterfaceName of string (* not a real type; used only during type checking *)
  | PackageName of string (* not a real type; used only during type checking *)
  | RefType of type_ (* not a real type; used only for locals whose address is taken *)
  | AbstractType of string
and inferred_type_state =
    Unconstrained
  | ContainsAnyConstraint of bool (* allow the type to contain 'any' in positive positions *)
  | EqConstraint of type_

let inferred_type_constraint_le c1 c2 =
  match c1, c2 with
    _, Unconstrained -> true
  | Unconstrained, _ -> false
  | _, ContainsAnyConstraint true -> true
  | ContainsAnyConstraint true, _ -> false
  | ContainsAnyConstraint false, ContainsAnyConstraint false -> true

let inferred_type_constraint_meet c1 c2 =
  if inferred_type_constraint_le c1 c2 then c1 else c2

type integer_limits = {max_unsigned_big_int: big_int; min_signed_big_int: big_int; max_signed_big_int: big_int}

let max_rank = 4 (* (u)int128 *)

let integer_limits_table =
  Array.init (max_rank + 1) begin fun k ->
    let max_unsigned_big_int = pred_big_int (shift_left_big_int unit_big_int (8 * (1 lsl k))) in
    let max_signed_big_int = shift_right_big_int max_unsigned_big_int 1 in
    let min_signed_big_int = pred_big_int (minus_big_int max_signed_big_int) in
    {max_unsigned_big_int; max_signed_big_int; min_signed_big_int}
  end

let max_unsigned_big_int k = integer_limits_table.(k).max_unsigned_big_int
let min_signed_big_int k = integer_limits_table.(k).min_signed_big_int
let max_signed_big_int k = integer_limits_table.(k).max_signed_big_int

type data_model = {int_rank: int; long_rank: int; ptr_rank: int}
let data_model_32bit = {int_rank=2; long_rank=2; ptr_rank=2}
let data_model_java = {int_rank=2; long_rank=3; ptr_rank=3 (*arbitrary value; ptr_rank is not relevant to Java programs*)}
let data_model_lp64 = {int_rank=2; long_rank=3; ptr_rank=3}
let data_model_llp64 = {int_rank=2; long_rank=2; ptr_rank=3}
let data_model_ip16 = {int_rank=1; long_rank=2; ptr_rank=1}
let data_model_i16 = {int_rank=1; long_rank=2; ptr_rank=2}
let data_models_ = [
  "IP16", data_model_ip16;
  "I16", data_model_i16;
  "32bit/ILP32", data_model_32bit;
  "Win64/LLP64", data_model_llp64;
  "Linux64/macOS/LP64", data_model_lp64
]
let data_models = [
  "IP16", data_model_ip16;
  "I16", data_model_i16;
  "ILP32", data_model_32bit;
  "32bit", data_model_32bit;
  "LLP64", data_model_llp64;
  "Win64", data_model_llp64;
  "LP64", data_model_lp64;
  "Unix64", data_model_lp64;
  "Linux64", data_model_lp64;
  "OSX", data_model_lp64;
  "macOS", data_model_lp64
]
let data_model_of_string s =
  let s = String.uppercase_ascii s in
  match head_flatmap_option (fun (k, v) -> if String.uppercase_ascii k = s then Some v else None) data_models with
    None -> failwith ("Data model must be one of " ^ String.concat ", " (List.map fst data_models))
  | Some v -> v
let intmax_rank = 3 (* Assume that sizeof(intmax_t) is always 8 *)

let is_arithmetic_type t =
  match t with
    Int (_, _)|RealType|Float|Double|LongDouble -> true
  | _ -> false

let is_inductive_type t =
  (match t with
  | InductiveType _ -> true
  | _ -> false
  )

type prover_type = ProverInt | ProverBool | ProverReal | ProverInductive (* ?prover_type *)

class predref (name: string) (domain: type_ list) (inputParamCount: int option) = (* ?predref *)
  object
    method name = name
    method domain = domain
    method inputParamCount = inputParamCount
    method is_precise = match inputParamCount with None -> false | Some _ -> true 
  end

type
  ident_scope = (* ?ident_scope *)
    LocalVar
  | PureCtor
  | FuncName
  | PredFamName
  | EnumElemName of big_int
  | GlobalName
  | ModuleName
  | PureFuncName
  | ClassOrInterfaceNameScope
  | PackageNameScope

type int_literal_lsuffix = NoLSuffix | LSuffix | LLSuffix

(** Types as they appear in source code, before validity checking and resolution. *)
type type_expr = (* ?type_expr *)
    StructTypeExpr of loc * string option * field list option * struct_attr list
  | UnionTypeExpr of loc * string option * field list option
  | EnumTypeExpr of loc * string option * (string * expr option) list option
  | PtrTypeExpr of loc * type_expr
  | ArrayTypeExpr of loc * type_expr
  | StaticArrayTypeExpr of loc * type_expr (* type *) * int (* number of elements*)
  | ManifestTypeExpr of loc * type_  (* A type expression that is obviously a given type. *)
  | IdentTypeExpr of loc * string option (* package name *) * string
  | ConstructedTypeExpr of loc * string * type_expr list  (* A type of the form x<T1, T2, ...> *)
  | PredTypeExpr of loc * type_expr list * int option (* if None, not necessarily precise; if Some n, precise with n input parameters *)
  | PureFuncTypeExpr of loc * type_expr list   (* Potentially uncurried *)
  | LValueRefTypeExpr of loc * type_expr
and
  operator =  (* ?operator *)
  | Add | Sub | PtrDiff | Le | Ge | Lt | Gt | Eq | Neq | And | Or | Xor | Not | Mul | Div | Mod | BitNot | BitAnd | BitXor | BitOr | ShiftLeft | ShiftRight
  | MinValue of type_ | MaxValue of type_
and
  expr = (* ?expr *)
    True of loc
  | False of loc
  | Null of loc
  | Var of loc * string
  | WVar of loc * string * ident_scope
  | TruncatingExpr of loc * expr
  | Operation of (* voor operaties met bovenstaande operators*)
      loc *
      operator *
      expr list
  | WOperation of (* see [woperation_result_type] *)
      loc *
      operator *
      expr list *
      type_
      (* The type of the first operand, after promotion and the usual arithmetic conversions.
         For all operators except the pointer offset and bitwise shift operators, this is also the type of the second operand, if any.
         For the pointer offset operators (Add and Sub where the first operand is a pointer) the second operand is of integral type.
         For all operators except the relational ones (whose result type is bool) and PtrDiff (whose result type is ptrdiff_t), this is also the type of the result.
         Used to select the right semantics (e.g. Real vs. Int vs. Bool) and for overflow checking.
         (Floating-point operations are turned into function calls by the type checker and do not appear as WOperation nodes.)
         If the operands have narrower types before promotion and conversion, they will be of the form Upcast (_, _, _). *)
  | IntLit of loc * big_int * bool (* decimal *) * bool (* U suffix *) * int_literal_lsuffix   (* int literal*)
  | WIntLit of loc * big_int
  | RealLit of loc * num
  | StringLit of loc * string (* string literal *)
  | ClassLit of loc * string (* class literal in java *)
  | Read of loc * expr * string (* lezen van een veld; hergebruiken voor java field access *)
  | Select of loc * expr * string (* reading a field in C; Java uses Read *)
  | ArrayLengthExpr of loc * expr
  (* Expression which returns the value of a field of an object *)
  | WRead of
      loc *
      expr *
      string (* parent *) *
      string (* field name *) *
      type_ (* range *) *
      bool (* static *) *
      constant_value option option ref *
      ghostness
  (* Expression which returns the value of a field of
   * a struct that is not an object - only for C *)
  | WSelect of
      loc *
      expr *
      string (* parent *) *
      string (* field name *) *
      type_ (* range *)
  (* Expression which returns the value of a field of an instance of an
   * inductive data type. *)
  | WReadInductiveField of
      loc *
      expr (* The expression which results an instance of the inductive
            * data type. (usually just a variable) *) *
      string (* inductive data type name *) *
      string (* constructor name *) *
      string (* field name *) *
      type_ list (* type arguments *)
  | ReadArray of loc * expr * expr
  | WReadArray of loc * expr * type_ * expr
  | Deref of (* pointer dereference *)
      loc *
      expr
  | WDeref of
      loc *
      expr *
      type_ (* pointee type *)
  | CallExpr of (* oproep van functie/methode/lemma/fixpoint *)
      loc *
      string *
      type_expr list (* type arguments *) *
      pat list (* indices, in case this is really a predicate assertion *) *
      pat list (* arguments *) *
      method_binding
  | ExprCallExpr of (* Call whose callee is an expression instead of a plain identifier *)
      loc *
      expr *
      expr list
  | WFunPtrCall of loc * string * expr list
  | WPureFunCall of loc * string * type_ list * expr list
  | WPureFunValueCall of loc * expr * expr list
  | WFunCall of loc * string * type_ list * expr list
  | WMethodCall of
      loc *
      string (* declaring class or interface *) *
      string (* method name *) *
      type_ list (* parameter types (not including receiver) *) *
      expr list (* args, including receiver if instance method *) *
      method_binding *
      (string * type_ ) list (* type param environment *)
  | NewArray of loc * type_expr * expr
  (* If type arguments are None -> regular object creation or raw objects. [] -> type inference required and if the list is populated: parameterised type creation *)
  | NewObject of loc * string * expr list * type_expr list option
  | CxxConstruct of 
      loc *
      string * (* constructor mangled name *)
      type_expr * (* type of object that will be constructed *)
      expr list (* args passed to constructor *)
  | WCxxConstruct of 
      loc *
      string *
      type_ *
      expr list
  | CxxNew of
      loc *
      type_expr *
      expr option (* construct expression *)
  | WCxxNew of
      loc * 
      type_ * 
      expr option
  | CxxDelete of
      loc *
      expr
  | NewArrayWithInitializer of loc * type_expr * expr list 
  | IfExpr of loc * expr * expr * expr
  | SwitchExpr of
      loc *
      expr *
      switch_expr_clause list *
      (loc * expr) option (* default clause *)
  | WSwitchExpr of
      loc *
      expr *
      string * (* inductive type, fully qualified *)
      type_ list * (* type arguments *)
      switch_expr_clause list *
      (loc * expr) option * (* default clause *)
      (string * type_) list * (* type environment *)
      type_ (* result type *)
  | PredNameExpr of loc * string (* naam van predicaat en line of code*)
  | CastExpr of loc * type_expr * expr (* cast *)
  | CxxLValueToRValue of loc * expr
  | CxxDerivedToBase of loc * expr * type_expr
  | Upcast of expr * type_ (* from *) * type_ (* to *)  (* Not generated by the parser; inserted by the typechecker. Required to prevent bad downcasts during autoclose. *)
  | TypedExpr of expr * type_  (* Not generated by the parser. In 'TypedExpr (e, t)', 't' should be the type of 'e'. Allows typechecked expression 'e' to be used where a not-yet-typechecked expression is expected. *)
  | WidenedParameterArgument of expr (* Appears only as part of LitPat (WidenedParameterArgument e). Indicates that the predicate parameter is considered to range over a larger set (e.g. Object instead of class C). *)
  | SizeofExpr of loc * expr
  | TypeExpr of type_expr (* Used to represent the E in 'sizeof E' when E is of the form '( T )' where T is a type *)
  | GenericExpr of loc * expr * (type_expr * expr) list * expr option (* default clause *) (* C11 generic selection (keyword '_Generic') *)
  | AddressOf of loc * expr
  | ProverTypeConversion of prover_type * prover_type * expr  (* Generated during type checking in the presence of type parameters, to get the prover types right *)
  | ArrayTypeExpr' of loc * expr (* horrible hack --- for well-formed programs, this exists only during parsing *)
  | AssignExpr of loc * expr * expr
  | AssignOpExpr of loc * expr * operator * expr * bool (* true = return value of lhs before operation *)
  | WAssignOpExpr of loc * expr * string * expr * bool
    (* Semantics of [WAssignOpExpr (l, lhs, x, rhs, postOp)]:
       1. Evaluate [lhs] to an lvalue L
       2. Get the value of L, call it v
       3. Evaluate [rhs] with x bound to v to an rvalue V
       4. Assign V to L
       5. Return (postOp ? v : V)
    *)
  | InstanceOfExpr of loc * expr * type_expr
  | SuperMethodCall of loc * string * expr list
  | WSuperMethodCall of loc * string (*superclass*) * string * expr list * (loc * ghostness * (type_ option) * (string * type_) list * asn * asn * (type_ * asn) list * bool (*terminates*) * int (*rank*) option * visibility)
  | InitializerList of loc * expr list
  | SliceExpr of loc * pat option * pat option
  | PointsTo of
        loc *
        expr *
        pat
  | WPointsTo of
      loc *
      expr *
      type_ *
      pat
  | PredAsn of (* Predicate assertion, before type checking *)
      loc *
      string *
      type_expr list *
      pat list (* indices of predicate family instance *) *
      pat list
  | WPredAsn of (* Predicate assertion, after type checking. (W is for well-formed) *)
      loc *
      predref *
      bool * (* prefref refers to global name *)
      type_ list *
      pat list *
      pat list
  | InstPredAsn of
      loc *
      expr *
      string *
      expr * (* index *)
      pat list
  | WInstPredAsn of
      loc *
      expr option *
      string (* static type *) *
      class_finality (* finality of static type *) *
      string (* family type *) *
      string *
      expr (* index *) *
      pat list
  | ExprAsn of (* uitdrukking regel-expr *)
      loc *
      expr
  | Sep of (* separating conjunction *)
      loc *
      asn *
      asn
  | IfAsn of (* if-predicate in de vorm expr? p1:p2 regel-expr-p1-p2 *)
      loc *
      expr *
      asn *
      asn
  | SwitchAsn of (* switch over cons van inductive type regel-expr-clauses*)
      loc *
      expr *
      switch_asn_clause list
  | WSwitchAsn of (* switch over cons van inductive type regel-expr-clauses*)
      loc *
      expr *
      string * (* inductive type (fully qualified) *)
      wswitch_asn_clause list
  | EmpAsn of  (* als "emp" bij requires/ensures staat -regel-*)
      loc
  | ForallAsn of 
      loc *
      type_expr *
      string *
      expr
  | CoefAsn of (* fractional permission met coeff-predicate*)
      loc *
      pat *
      asn
  | EnsuresAsn of loc * asn
  | MatchAsn of loc * expr * pat
  | WMatchAsn of loc * expr * pat * type_
and
  asn = expr
and
  pat = (* ?pat *)
    LitPat of expr (* literal pattern *)
  | VarPat of loc * string (* var pattern, aangeduid met ? in code *)
  | DummyPat (*dummy pattern, aangeduid met _ in code *)
  | CtorPat of loc * string * pat list
  | WCtorPat of loc * string * type_ list * string * type_ list * type_ list * pat list
and
  switch_asn_clause = (* ?switch_asn_clause *)
  | SwitchAsnClause of
      loc * 
      string * 
      string list * 
      asn
and
  wswitch_asn_clause = (* ?switch_asn_clause *)
  | WSwitchAsnClause of
      loc * 
      string * 
      string list * 
      prover_type option list (* Boxing info *) *
      asn
and
  switch_expr_clause = (* ?switch_expr_clause *)
    SwitchExprClause of
      loc *
      string (* constructor name *) *
      string list (* argument names *) *
      expr (* body *)
and
  language = (* ?language *)
    Java
  | CLang
and
  dialect = (* ?dialect *)
    | Cxx
and
  method_binding = (* ?method_binding *)
    Static
  | Instance
and
  visibility = (* ?visibility *)
    Public
  | Protected
  | Private
  | Package
and
  package = (* ?package *)
    PackageDecl of loc * string * import list * decl list
and
  import = (* ?import *)
    Import of
        loc *
        ghostness *
        string *
        string option (* None betekent heel package, Some string betekent 1 ding eruit *)
and 
  producing_handle_predicate =
    ConditionalProducingHandlePredicate of loc * expr (* condition *) * string (* handle name *) * (expr list) (* args *) * producing_handle_predicate
  | BasicProducingHandlePredicate of loc * string (* handle name *) * (expr list) (* args *)
and
  consuming_handle_predicate = 
    ConsumingHandlePredicate of loc * string * (pat list)
and
  stmt = (* ?stmt *)
    PureStmt of (* Statement of the form /*@ ... @*/ *)
        loc *
        stmt
  | NonpureStmt of (* Nested non-pure statement; used for perform_action statements on shared boxes. *)
      loc *
      bool (* allowed *) *
      stmt
  | DeclStmt of (* enkel declaratie *)
      loc *
      (loc * type_expr * string * expr option * (bool ref (* indicates whether address is taken *) * string list ref option ref (* pointer to enclosing block's list of variables whose address is taken *))) list
  | ExprStmt of expr
  | IfStmt of (* if  regel-conditie-branch1-branch2  *)
      loc *
      expr *
      stmt list *
      stmt list
  | SwitchStmt of (* switch over inductief type regel-expr- constructor)*)
      loc *
      expr *
      switch_stmt_clause list
  | Assert of loc * asn (* assert regel-predicate *)
  | Leak of loc * asn (* expliciet lekken van assertie, nuttig op einde van thread*)
  | Open of
      loc *
      expr option *  (* Target object *)
      string *
      type_expr list *  (* Type arguments *)
      pat list *  (* Indices for predicate family instance, or constructor arguments for predicate constructor *)
      pat list *  (* Arguments *)
      pat option  (* Coefficient for fractional permission *)
  | Close of
      loc *
      expr option *
      string *
      type_expr list *
      pat list *
      pat list *
      pat option
  | ReturnStmt of loc * expr option (*return regel-return value (optie) *)
  | WhileStmt of
      loc *
      expr *
      loop_spec option *
      expr option * (* decreases clause *)
      stmt list * (* body *)
      stmt list (* statements to be executed after the body: for increment or do-while condition check. 'continue' jumps here. *)
  | BlockStmt of
      loc *
      decl list *
      stmt list *
      loc *
      string list ref
  | PerformActionStmt of
      loc *
      bool ref (* in non-pure context *) *
      string *
      pat list *
      consuming_handle_predicate list *
      loc *
      string *
      expr list *
      stmt list *
      loc (* close brace of body *) *
      (loc * expr list) option *
      (bool (* indicates whether a fresh handle id should be generated *) * producing_handle_predicate) list
      (*loc *
      string *
      expr list*)
  | SplitFractionStmt of (* split_fraction ... by ... *)
      loc *
      string *
      type_expr list *
      pat list *
      expr option
  | MergeFractionsStmt of (* merge_fraction ...*)
      loc *
      asn
  | CreateBoxStmt of
      loc *
      string *
      string *
      expr list *
      expr list * (* lower bounds *)
      expr list * (* upper bounds *)
      (loc * string * bool (* indicates whether an is_handle chunk is generated *) * string * expr list) list (* and_handle clauses *)
  | CreateHandleStmt of
      loc *
      string *
      bool * (* indicates whether an is_handle chunk is generated *)
      string *
      expr
  | DisposeBoxStmt of
      loc *
      string *
      pat list *
      (loc * string * pat list) list (* and_handle clauses *)
  | LabelStmt of loc * string
  | GotoStmt of loc * string
  | NoopStmt of loc
  | InvariantStmt of
      loc *
      asn (* join point *)
  | ProduceLemmaFunctionPointerChunkStmt of
      loc *
      expr option *
      (string * type_expr list * expr list * (loc * string) list * loc * stmt list * loc) option *
      stmt option
  | DuplicateLemmaFunctionPointerChunkStmt of
      loc *
      expr
  | ProduceFunctionPointerChunkStmt of
      loc *
      string * (* name of function typedef *)
      expr * (* function pointer expression *)
      type_expr list * (* type argument *)
      expr list *
      (loc * string) list *
      loc *
      stmt list *
      loc
  | Throw of loc * expr
  | TryCatch of
      loc *
      stmt list *
      (loc * type_expr * string * stmt list) list
  | TryFinally of
      loc *
      stmt list *
      loc *
      stmt list
  | Break of loc
  | SuperConstructorCall of loc * expr list
and
  loop_spec = (* ?loop_spec *)
  | LoopInv of asn
  | LoopSpec of asn * asn
and
  switch_stmt_clause = (* ?switch_stmt_clause *)
  | SwitchStmtClause of loc * expr * stmt list
  | SwitchStmtDefaultClause of loc * stmt list
and
  func_kind = (* ?func_kind *)
  | Regular
  | Fixpoint
  | Lemma of bool (* indicates whether an axiom should be generated for this lemma *) * expr option (* trigger *)
and
  meth = (* ?meth *)
  | Meth of
      loc * 
      ghostness * 
      type_expr option * 
      string * 
      (type_expr * string) list * 
      (asn * asn * ((type_expr * asn) list) * bool (*terminates*) ) option * 
      ((stmt list * loc (* Close brace *)) * int (*rank*)) option * 
      method_binding * 
      visibility *
      bool * (* is declared abstract? *)
      string list (* tparams *)
and
  cons = (* ?cons *)
  | Cons of
      loc * 
      (type_expr * string) list * 
      (asn * asn * ((type_expr * asn) list) * bool (*terminates*) ) option * 
      ((stmt list * loc (* Close brace *)) * int (*rank*)) option * 
      visibility
and
  instance_pred_decl = (* ?instance_pred_decl *)
  | InstancePredDecl of loc * string * (type_expr * string) list * asn option
and
  class_finality =
  | FinalClass
  | ExtensibleClass
and
  decl = (* ?decl *)
    Struct of 
      loc * 
      string * 
      (base_spec list * field list) option *
      struct_attr list
  | Union of loc * string * field list option
  | Inductive of  (* inductief data type regel-naam-type parameters-lijst van constructors*)
      loc *
      string *
      string list * (*tparams*)
      ctor list
  | AbstractTypeDecl of loc * string
  | Class of
      loc *
      bool (* abstract *) *
      class_finality *
      string * (* class name *)
      meth list *
      field list *
      cons list *
      (string * type_expr list) (* superclass with targs *) *
      string list (* type parameters *) *
      (string * type_expr list) list (* itfs with targs *) *
      instance_pred_decl list
  | Interface of 
      loc *
      string *
      (string * type_expr list) list * (* interfaces *)
      field list *
      meth list *
      string list * (* type parameters *) 
      instance_pred_decl list
  | PredFamilyDecl of
      loc *
      string *
      string list (* type parameters *) *
      int (* number of indices *) *
      type_expr list *
      int option (* (Some n) means the predicate is precise and the first n parameters are input parameters *) *
      inductiveness
  | PredFamilyInstanceDecl of
      loc *
      string *
      string list (* type parameters *) *
      (loc * string) list *
      (type_expr * string) list *
      asn
  | PredCtorDecl of
      loc *
      string *
      (type_expr * string) list *
      (type_expr * string) list *
      int option * (* (Some n) means the predicate is precise and the first n parameters are input parameters *)
      asn
  | Func of
      loc *
      func_kind *
      string list *  (* type parameters *)
      type_expr option *  (* return type *)
      string *  (* name *)
      (type_expr * string) list *  (* parameters *)
      bool (* nonghost_callers_only *) *
      (string * type_expr list * (loc * string) list) option (* implemented function type, with function type type arguments and function type arguments *) *
      (asn * asn) option *  (* contract *)
      bool *  (* terminates *)
      (stmt list * loc (* Close brace *)) option *  (* body *)
      method_binding *  (* static or instance *)
      visibility
  | CxxCtor of 
      loc *
      string * (* mangled name *)
      (type_expr * string) list * (* params *)
      (asn * asn) option * (* pre post *)
      bool * (* terminates *)
      ((string * (expr * bool (* is written *)) option) list (* init list *) * (stmt list * loc (* close brace *))) option *
      bool * (* implicit *)
      type_ (* parent type *)
  | CxxDtor of 
      loc *
      (asn * asn) option * (* pre post *)
      bool * (* terminates *)
      (stmt list * loc (* close brace *)) option *
      bool * (* implicit *)
      type_ (* parent type *)
  (** Do not confuse with FuncTypeDecl *)
  | TypedefDecl of
      loc *
      type_expr *
      string
      
  (** Used for declaring a function type like "typedef void myfunc();"
    * or "typedef lemma ..."
    *)
  | FuncTypeDecl of
      loc *
      ghostness * (* e.g. a "typedef lemma" is ghost. *)
      type_expr option * (* return type *)
      string *
      string list * (* type parameters *)
      (type_expr * string) list *
      (type_expr * string) list *
      (asn * asn * bool) (* precondition, postcondition, terminates *)
  | BoxClassDecl of
      loc *
      string *
      (type_expr * string) list *
      asn *
      action_decl list *
      handle_pred_decl list
  (* enum def met line - name - elements *)
  | EnumDecl of loc * string * (string * expr option) list
  | Global of loc * type_expr * string * expr option
  | UnloadableModuleDecl of loc
  | ImportModuleDecl of loc * string
  | RequireModuleDecl of loc * string
and (* shared box is deeltje ghost state, waarde kan enkel via actions gewijzigd worden, handle predicates geven info over de ghost state, zelfs als er geen eigendom over de box is*)
  action_decl = (* ?action_decl *)
  | ActionDecl of loc * string * bool (* does performing this action require a corresponding action permission? *) * (type_expr * string) list * expr * expr
and (* action, kan value van shared box wijzigen*)
  handle_pred_decl = (* ?handle_pred_decl *)
  | HandlePredDecl of loc * string * (type_expr * string) list * string option (* extends *) * asn * preserved_by_clause list
and (* handle predicate geeft info over ghost state van shared box, zelfs als er geen volledige eigendom is vd box*)
  preserved_by_clause = (* ?preserved_by_clause *)
  | PreservedByClause of loc * string * string list * stmt list
and
  ghostness = (* ?ghostness *)
  | Ghost
  | Real
and
  field =
  | Field of (* ?field *)
      loc *
      ghostness *
      type_expr *
      string (* name of the field *) *
      method_binding *
      visibility *
      bool (* final *) *
      expr option
and 
  base_spec =
  | CxxBaseSpec of
      loc * 
      string * (* record name *)
      bool (* virtual *)
and
  ctor = (* ?ctor *)
  | Ctor of
    loc *
    string * (* name of the constructor *)
    (string * type_expr) list (* name and type-expression of the arguments *)
    
and
  member = (* ?member *)
  | FieldMember of field list
  | MethMember of meth
  | ConsMember of cons
  | PredMember of instance_pred_decl
and
  struct_attr =
  | Packed

let func_kind_of_ghostness gh =
  match gh with
    Real -> Regular
  | Ghost -> Lemma (false, None)
  
(* Region: some AST inspector functions *)

let string_of_func_kind f=
  match f with
    Lemma(_) -> "lemma"
  | Regular -> "regular"
  | Fixpoint -> "fixpoint"
let tostring f=
  match f with
  Instance -> "instance"
  | Static -> "static"
let rec expr_loc e =
  match e with
    True l -> l
  | False l -> l
  | Null l -> l
  | Var (l, x) | WVar (l, x, _) -> l
  | IntLit (l, n, _, _, _) -> l
  | WIntLit (l, n) -> l
  | RealLit (l, n) -> l
  | StringLit (l, s) -> l
  | ClassLit (l, s) -> l
  | TruncatingExpr (l, e) -> l
  | Operation (l, op, es) -> l
  | WOperation (l, op, es, t) -> l
  | SliceExpr (l, p1, p2) -> l
  | Read (l, e, f)
  | Select (l, e, f) -> l
  | ArrayLengthExpr (l, e) -> l
  | WSelect (l, _, _, _, _) -> l
  | WRead (l, _, _, _, _, _, _, _) -> l
  | WReadInductiveField(l, _, _, _, _, _) -> l
  | ReadArray (l, _, _) -> l
  | WReadArray (l, _, _, _) -> l
  | Deref (l, e) -> l
  | WDeref (l, e, t) -> l
  | CallExpr (l, g, targs, pats0, pats,_) -> l
  | ExprCallExpr (l, e, es) -> l
  | WPureFunCall (l, g, targs, args) -> l
  | WPureFunValueCall (l, e, es) -> l
  | WFunPtrCall (l, g, args) -> l
  | WFunCall (l, g, targs, args) -> l
  | WMethodCall (l, tn, m, pts, args, fb, tparamEnv) -> l
  | NewObject (l, cn, args, targs) -> l
  | NewArray(l, _, _) -> l
  | NewArrayWithInitializer (l, _, _) -> l
  | IfExpr (l, e1, e2, e3) -> l
  | SwitchExpr (l, e, secs, _) -> l
  | WSwitchExpr (l, e, i, targs, secs, cdef, tenv, t0) -> l
  | SizeofExpr (l, e) -> l
  | GenericExpr (l, e, cs, d) -> l
  | PredNameExpr (l, g) -> l
  | CastExpr (l, te, e) -> l
  | Upcast (e, fromType, toType) -> expr_loc e
  | TypedExpr (e, t) -> expr_loc e
  | WidenedParameterArgument e -> expr_loc e
  | AddressOf (l, e) -> l
  | ArrayTypeExpr' (l, e) -> l
  | AssignExpr (l, lhs, rhs) -> l
  | AssignOpExpr (l, lhs, op, rhs, postOp) -> l
  | WAssignOpExpr (l, lhs, x, rhs, postOp) -> l
  | ProverTypeConversion (t1, t2, e) -> expr_loc e
  | InstanceOfExpr(l, e, tp) -> l
  | SuperMethodCall(l, _, _) -> l
  | WSuperMethodCall(l, _, _, _, _) -> l
  | InitializerList (l, _) -> l
  | PointsTo (l, e, rhs) -> l
  | WPointsTo (l, e, tp, rhs) -> l
  | PredAsn (l, g, targs, ies, es) -> l
  | WPredAsn (l, g, _, targs, ies, es) -> l
  | InstPredAsn (l, e, g, index, pats) -> l
  | WInstPredAsn (l, e_opt, tns, cfin, tn, g, index, pats) -> l
  | ExprAsn (l, e) -> l
  | MatchAsn (l, e, pat) -> l
  | WMatchAsn (l, e, pat, tp) -> l
  | Sep (l, p1, p2) -> l
  | IfAsn (l, e, p1, p2) -> l
  | SwitchAsn (l, e, sacs) -> l
  | WSwitchAsn (l, e, i, sacs) -> l
  | EmpAsn l -> l
  | ForallAsn (l, tp, i, e) -> l
  | CoefAsn (l, coef, body) -> l
  | EnsuresAsn (l, body) -> l
  | CxxNew (l, _, _)
  | WCxxNew (l, _, _) -> l
  | CxxDelete (l, _) -> l
  | CxxConstruct (l, _, _, _)
  | WCxxConstruct (l, _, _, _) -> l
  | CxxLValueToRValue (l, _) -> l
  | CxxDerivedToBase (l, _, _) -> l
let asn_loc a = expr_loc a
  
let stmt_loc s =
  match s with
    PureStmt (l, _) -> l
  | NonpureStmt (l, _, _) -> l
  | ExprStmt e -> expr_loc e
  | DeclStmt (l, _) -> l
  | IfStmt (l, _, _, _) -> l
  | SwitchStmt (l, _, _) -> l
  | Assert (l, _) -> l
  | Leak (l, _) -> l
  | Open (l, _, _, _, _, _, coef) -> l
  | Close (l, _, _, _, _, _, coef) -> l
  | ReturnStmt (l, _) -> l
  | WhileStmt (l, _, _, _, _, _) -> l
  | Throw (l, _) -> l
  | TryCatch (l, _, _) -> l
  | TryFinally (l, _, _, _) -> l
  | BlockStmt (l, ds, ss, _, _) -> l
  | PerformActionStmt (l, _, _, _, _, _, _, _, _, _, _, _) -> l
  | SplitFractionStmt (l, _, _, _, _) -> l
  | MergeFractionsStmt (l, _) -> l
  | CreateBoxStmt (l, _, _, _, _, _, _) -> l
  | CreateHandleStmt (l, _, _, _, _) -> l
  | DisposeBoxStmt (l, _, _, _) -> l
  | LabelStmt (l, _) -> l
  | GotoStmt (l, _) -> l
  | NoopStmt l -> l
  | InvariantStmt (l, _) -> l
  | ProduceLemmaFunctionPointerChunkStmt (l, _, _, _) -> l
  | DuplicateLemmaFunctionPointerChunkStmt (l, _) -> l
  | ProduceFunctionPointerChunkStmt (l, ftn, fpe, targs, args, params, openBraceLoc, ss, closeBraceLoc) -> l
  | Break (l) -> l
  | SuperConstructorCall(l, _) -> l

let stmt_fold_open f state s =
  match s with
    PureStmt (l, s) -> f state s
  | NonpureStmt (l, _, s) -> f state s
  | IfStmt (l, _, sst, ssf) -> let state = List.fold_left f state sst in List.fold_left f state ssf
  | SwitchStmt (l, _, cs) ->
    let rec iter state c =
      match c with
        SwitchStmtClause (l, e, ss) -> List.fold_left f state ss
      | SwitchStmtDefaultClause (l, ss) -> List.fold_left f state ss
    in
    List.fold_left iter state cs
  | WhileStmt (l, _, _, _, ss, final_ss) -> let state = List.fold_left f state ss in List.fold_left f state final_ss
  | TryCatch (l, ss, ccs) ->
    let state = List.fold_left f state ss in
    List.fold_left (fun state (_, _, _, ss) -> List.fold_left f state ss) state ccs
  | TryFinally (l, ssb, _, ssf) ->
    let state = List.fold_left f state ssb in
    List.fold_left f state ssf
  | BlockStmt (l, ds, ss, _, _) ->
    let process_decl state = function
      Func (_, _, _, _, _, _, _, _, _, _, Some (ss, _), _, _) ->
      List.fold_left f state ss
    | _ -> state
    in
    let state = List.fold_left process_decl state ds in
    List.fold_left f state ss
  | PerformActionStmt (l, _, _, _, _, _, _, _, ss, _, _, _) -> List.fold_left f state ss
  | ProduceLemmaFunctionPointerChunkStmt (l, _, proofo, ssbo) ->
    let state =
      match proofo with
        None -> state
      | Some (_, _, _, _, _, ss, _) -> List.fold_left f state ss
    in
    begin match ssbo with
      None -> state
    | Some ss -> f state ss
    end
  | ProduceFunctionPointerChunkStmt (l, ftn, fpe, targs, args, params, openBraceLoc, ss, closeBraceLoc) -> List.fold_left f state ss
  | _ -> state

let is_lvalue_ref_type_expr = function 
  | LValueRefTypeExpr _ -> true | _ -> false

(* Postfix fold *)
let stmt_fold f state s =
  let rec iter state s =
    let state = stmt_fold_open iter state s in
    f state s
  in
  iter state s

(* Postfix iter *)
let stmt_iter f s = stmt_fold (fun _ s -> f s) () s

let type_expr_loc t =
  match t with
    ManifestTypeExpr (l, t) -> l
  | StructTypeExpr (l, sn, _, _) -> l
  | UnionTypeExpr (l, un, _) -> l
  | IdentTypeExpr (l, _, x) -> l
  | ConstructedTypeExpr (l, x, targs) -> l
  | PtrTypeExpr (l, te) -> l
  | ArrayTypeExpr(l, te) -> l
  | PredTypeExpr(l, te, _) -> l
  | PureFuncTypeExpr (l, tes) -> l

let expr_fold_open iter state e =
  let rec iters state es =
    match es with
      [] -> state
    | e::es -> iters (iter state e) es
  and iterpat state pat =
    match pat with
      LitPat e -> iter state e
    | _ -> state
  and iterpatopt state patopt =
    match patopt with
      None -> state
    | Some pat -> iterpat state pat
  and iterpats state pats =
    match pats with
      [] -> state
    | pat::pats -> iterpats (iterpat state pat) pats
  and itercs state cs =
    match cs with
      [] -> state
    | SwitchExprClause (l, cn, pats, e)::cs -> itercs (iter state e) cs
  in
  match e with
    True l -> state
  | False l -> state
  | Null l -> state
  | Var (l, x) | WVar (l, x, _) -> state
  | TruncatingExpr (l, e) -> iter state e
  | Operation (l, op, es) -> iters state es
  | WOperation (l, op, es, t) -> iters state es
  | SliceExpr (l, p1, p2) -> iterpatopt (iterpatopt state p1) p2
  | IntLit (l, n, _, _, _) -> state
  | WIntLit (l, n) -> state
  | RealLit(l, n) -> state
  | StringLit (l, s) -> state
  | ClassLit (l, cn) -> state
  | Read (l, e0, f)
  | Select (l, e0, f) -> iter state e0
  | ArrayLengthExpr (l, e0) -> iter state e0
  | WRead (l, e0, fparent, fname, frange, fstatic, fvalue, fghost) -> if fstatic then state else iter state e0
  | WSelect (l, e0, fparent, fname, frange) -> iter state e0
  | WReadInductiveField (l, e0, ind_name, constr_name, field_name, targs) -> iter state e0
  | ReadArray (l, a, i) -> let state = iter state a in let state = iter state i in state
  | WReadArray (l, a, tp, i) -> let state = iter state a in let state = iter state i in state
  | Deref (l, e0) -> iter state e0
  | WDeref (l, e0, tp) -> iter state e0
  | CallExpr (l, g, targes, pats0, pats, mb) -> let state = iterpats state pats0 in let state = iterpats state pats in state
  | ExprCallExpr (l, e, es) -> iters state (e::es)
  | WPureFunCall (l, g, targs, args) -> iters state args
  | WPureFunValueCall (l, e, args) -> iters state (e::args)
  | WFunCall (l, g, targs, args) -> iters state args
  | WFunPtrCall (l, g, args) -> iters state args
  | WMethodCall (l, cn, m, pts, args, mb, tparamEnv) -> iters state args
  | NewObject (l, cn, args, targs) -> iters state args
  | NewArray (l, te, e0) -> iter state e0
  | NewArrayWithInitializer (l, te, es) -> iters state es
  | IfExpr (l, e1, e2, e3) -> iters state [e1; e2; e3]
  | SwitchExpr (l, e0, cs, cdef_opt) | WSwitchExpr (l, e0, _, _, cs, cdef_opt, _, _) -> let state = itercs (iter state e0) cs in (match cdef_opt with Some (l, e) -> iter state e | None -> state)
  | PredNameExpr (l, p) -> state
  | CastExpr (l, te, e0) -> iter state e0
  | Upcast (e, fromType, toType) -> iter state e
  | TypedExpr (e, t) -> iter state e
  | WidenedParameterArgument e -> iter state e
  | SizeofExpr (l, e) -> state
  | GenericExpr (l, e, cs, d) ->
    let state = iter state e in
    let rec iter_cases state = function
      [] -> state
    | (te, e)::cs ->
      let state = iter state e in
      iter_cases state cs
    in
    let state = iter_cases state cs in
    begin match d with
      None -> state
    | Some e -> iter state e
    end
  | AddressOf (l, e0) -> iter state e0
  | ProverTypeConversion (pt, pt0, e0) -> iter state e0
  | ArrayTypeExpr' (l, e) -> iter state e
  | AssignExpr (l, lhs, rhs) -> iter (iter state lhs) rhs
  | AssignOpExpr (l, lhs, op, rhs, post) -> iter (iter state lhs) rhs
  | WAssignOpExpr (l, lhs, x, rhs, post) -> iter (iter state lhs) rhs
  | InstanceOfExpr(l, e, tp) -> iter state e
  | SuperMethodCall(_, _, args) -> iters state args
  | WSuperMethodCall(_, _, _, args, _) -> iters state args
  | InitializerList (l, es) -> iters state es
  | CxxNew (_, _, Some e)
  | WCxxNew (_, _, Some e) -> iter state e
  | CxxNew (_, _, _)
  | WCxxNew (_, _, _) -> state
  | CxxDelete (_, arg) -> iter state arg

(* Postfix fold *)
let expr_fold f state e = let rec iter state e = f (expr_fold_open iter state e) e in iter state e

let expr_iter f e = expr_fold (fun state e -> f e) () e

let expr_flatmap f e = expr_fold (fun state e -> f e @ state) [] e

let rec make_addr_of (loc: loc) (expr: expr): expr =
  match expr with
  | CxxDerivedToBase (d_l, d_e, d_t) ->
    let addr_of_e = make_addr_of loc d_e in
    CxxDerivedToBase (d_l, addr_of_e, PtrTypeExpr (d_l, d_t))
  | _ ->
    AddressOf (loc, expr)