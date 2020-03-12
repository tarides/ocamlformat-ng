open Source_parsing
open Asttypes
open Source_tree

open Document
open struct type document = Document.t end

open Custom_combinators

let module_name ~loc = function
  | None -> underscore ~loc
  | Some name -> string ~loc name

module Tokens = struct
  open PPrint

  let pipe = char '|'

  let and_ = string "and"

  let as_ = string "as"

  let arrow = string "->"

  let larrow = string "<-"

  let exception_ = string "exception"

  let module_ = string "module"

  let of_ = string "of"

  let dotdot = string ".."

  let lazy_ = string "lazy"

  let let_ = string "let"

  let in_ = string "in"
end
open Tokens

module Ident_class = struct
  type t =
    | Prefix_op of string
    | Infix_op of string
    | Normal

  (* Refer to:
     http://caml.inria.fr/pub/docs/manual-ocaml/lex.html#sss:lex-ops-symbols *)
  let classify s =
    match s with
    | "" -> assert false
    | ":=" | "or" | "&" | "&&" | "!=" | "mod" | "land" | "lor" | "lxor"
    | "lsl" | "lsr" | "asr" | "::" -> Infix_op s
    | _ ->
      match String.get s 0 with
      | '!' | '?' | '~' -> Prefix_op s
      | '$' | '&' | '*' | '+' | '-' | '/' | '=' | '>' | '@' | '^' | '|'
      | '%' | '<' | '#' -> Infix_op s
      | _ -> Normal
end

module Longident : sig
  val pp : Long_ident.t -> document
end = struct
  open Long_ident

  let pp_ident s =
    match Ident_class.classify s.txt with
    | Normal -> str s
    | Infix_op _ | Prefix_op _ -> parens (str s)

  let rec pp = function
    | Lident s -> pp_ident s
    | Ldot (lid, s) -> concat (pp lid) ~sep:PPrint.(dot ^^ break 0) (str s)
    | Lapply (l1, l2) -> concat (pp l1) ~sep:(break 0) (parens (pp l2))

  let pp lid = hang 2 (pp lid)

  let () = Constructor_decl.pp_longident := pp
end

module Constant : sig
  val pp : loc:Location.t -> constant -> document
end = struct
  let pp_string_lit ~loc s = arbitrary_string ~loc (String.escaped s)
  let pp_quoted_string ~loc ~delim s =
    let delim = PPrint.string delim in
    braces (
      enclose ~before:PPrint.(delim ^^ pipe) ~after:PPrint.(pipe ^^ delim)
        (arbitrary_string ~loc s)
    )

  let pp ~loc = function
    | Pconst_float (nb, suffix_opt)
    | Pconst_integer (nb, suffix_opt) ->
      let nb =
        match suffix_opt with
        | None -> nb
        | Some s -> nb ^ (String.make 1 s)
      in
      (* FIXME? nb might start with a minus… which might implying parenthesing
         is required in some contexts. *)
      string ~loc nb
    | Pconst_char c                   -> squotes (char ~loc c)
    | Pconst_string (s, None)         -> dquotes (pp_string_lit ~loc s)
    | Pconst_string (s, Some delim)   -> pp_quoted_string ~loc ~delim s
end

module Polymorphic_variant_tag : sig
  val pp : label loc -> document
end = struct
  let pp tag = string ~loc:tag.loc ("`" ^ tag.txt)
end

module rec Attribute : sig
  type kind =
    | Free_floating
    | Attached_to_structure_item
    | Attached_to_item

  val pp : kind -> attribute -> document

  val attach : kind -> document -> attributes -> document
  val attach_to_item : document -> attributes -> document
  val attach_to_top_item : document -> attributes -> document
end = struct
  type kind =
    | Free_floating
    | Attached_to_structure_item
    | Attached_to_item

  let ats kind =
    match kind with
    | Free_floating -> "@@@"
    | Attached_to_structure_item -> "@@"
    | Attached_to_item -> "@"

  let pp_attr kind attr_name attr_payload =
    let tag = string ~loc:attr_name.loc (ats kind ^ attr_name.txt) in
    brackets (Payload.pp_after ~tag attr_payload)

  (* :/ *)
  let pp_doc ~loc = function
    | PStr [
        { pstr_desc =
            Pstr_eval ({ pexp_desc =
                           Pexp_constant Pconst_string (s, None); _ }, []); _ }
      ] ->
      let doc =
        let open PPrint in
        let doc = separate hardline (lines s) in
        !^"(**" ^^ doc ^^ !^"*)"
      in
      Location.mkloc doc loc
    | _ -> assert false

  let pp kind { attr_name; attr_payload; attr_loc } =
    match attr_name.txt with
    | "ocaml.doc" ->
      assert (kind <> Free_floating);
      pp_doc attr_payload ~loc:attr_loc
    | "ocaml.text" ->
      (*
         The following is not true in cases like:
         {[
           type a = Foo | Bar

           (** Haha! *)

           and b = { x : int }
         ]}

         TODO? handle docstring before the call to [pp], i.e. directly in
         [attach]. So in cases like this… we don't attach (that is: we don't
         indent)?

      assert (kind = Free_floating);
      *)
      pp_doc attr_payload ~loc:attr_loc
    | _ ->
      pp_attr kind attr_name attr_payload

  let attach kind doc = function
    | [] -> doc
    | attr :: attrs ->
      group (
        prefix ~indent:2 ~spaces:1 doc 
          (separate_map (PPrint.break 0) ~f:(pp kind) attr attrs)
      )

  let attach_to_item doc =
    attach Attached_to_item doc

  let () = Constructor_decl.attach_attributes := attach_to_item

  let attach_to_top_item doc =
    attach Attached_to_structure_item doc
end

and Extension : sig
  type kind =
    | Structure_item
    | Item

  val pp : kind -> extension -> document
end = struct
  type kind =
    | Structure_item
    | Item

  let percents = function
    | Structure_item -> "%%"
    | Item -> "%"

  let pp kind ({ Location.txt = ext_name; loc }, ext_payload) =
    let tag = string ~loc (percents kind ^ ext_name) in
    brackets (Payload.pp_after ~tag ext_payload)
end

and Payload : sig
  val pp_after : tag:document -> payload -> document
end = struct
  let psig tag sg =
    let sg = Signature.pp sg in
    let colon = token_between tag sg ":" in
    tag ^^ nest 2 (colon ^/^ sg)

  let ptyp tag ct =
    let ct = Core_type.pp [] ct in
    let colon = token_between tag ct ":" in
    tag ^^ nest 2 (colon ^/^ ct)

  let ppat tag p =
    let p = Pattern.pp [] p in
    let qmark = token_between tag p "?" in
    tag ^^ nest 2 (qmark ^/^ p)

  let ppat_guard tag p e =
    let p = Pattern.pp [] p in
    let e = Expression.pp [] e in
    let qmark = token_between tag p "?" in
    let when_ = token_between p e "when" in
    tag ^^ nest 2 (
      qmark ^/^ p ^/^
      group (when_ ^/^ e)
    )

  let pp_after ~tag = function
    | PStr st -> nest 2 (break_before @@ Structure.pp st)
    | PSig sg -> psig tag sg
    | PTyp ct -> ptyp tag ct
    | PPat (p, None) -> ppat tag p
    | PPat (p, Some e) -> ppat_guard tag p e
end

and Core_type : sig
  val pp : Printing_stack.t -> core_type -> document
end = struct
  let pp_var ~loc v = string ~loc ("'" ^ v)

  let rec pp ps ct =
    let ps = Printing_stack.Core_type ct.ptyp_desc :: ps in
    group (pp_desc ~loc:ct.ptyp_loc ps ct.ptyp_desc)

  and pp_desc ~loc ps = function
    | Ptyp_any -> underscore ~loc
    | Ptyp_var v -> pp_var ~loc v
    | Ptyp_arrow (params, ct2) -> pp_arrow ps params ct2
    | Ptyp_tuple lst -> pp_tuple ps lst
    | Ptyp_constr (name, args) -> pp_constr ps name args
    | Ptyp_object (fields, closed) -> pp_object ~loc fields closed
    | Ptyp_class (name, args) -> pp_class ps name args
    | Ptyp_alias (ct, alias) -> pp_alias ps ct alias
    | Ptyp_variant (fields, closed, present) -> pp_variant fields closed present
    | Ptyp_poly (vars, ct) -> pp_poly vars ct
    | Ptyp_package pkg -> pp_package pkg
    | Ptyp_extension ext -> Extension.pp Item ext

  and pp_param ps (arg_label, ct) =
    let ct = pp ps ct in
    match arg_label with
    | Nolabel -> ct
    | Labelled l -> concat (str l) ~sep:PPrint.(colon ^^ break 0) ct
    | Optional l ->
      let opt_label = string ~loc:l.loc ("?" ^ l.txt) in
      concat opt_label ct ~sep:PPrint.(colon ^^ break 0)

  and pp_arrow ps params res =
    let params =
      match params with
      | [] -> assert false
      | x :: xs ->
        left_assoc_map ~sep:PPrint.(arrow ^^ space) ~f:(pp_param ps) x xs
    in
    let res = pp (List.tl ps) res in
    let arrow = token_between params res "->" in
    let doc = params ^/^ group (arrow ^/^ res) in
    Printing_stack.parenthesize ps doc

  and pp_tuple ps = function
    | [] -> assert false
    | x :: xs ->
      let doc = left_assoc_map ~sep:PPrint.(star ^^ break 1) ~f:(pp ps) x xs in
      Printing_stack.parenthesize ps doc

  and pp_constr ps name args =
    let name = Longident.pp name in
    match args with
    | [] -> name
    | x :: xs -> pp_params ps x xs ^/^ name

  and pp_params ps first = function
    | []   -> pp ps first
    | rest -> parens (separate_map comma ~f:(pp []) first rest)

  and pp_object ~loc fields closed =
    let semi_sep = PPrint.(semi ^^ break 1) in
    let fields = List.rev_map Object_field.pp fields in
    let fields =
      match closed with
      | OClosed -> fields
      | OOpen loc -> fields @ [ string ~loc ".." ]
    in
    let fields =
      match fields with
      | [] -> empty ~loc
      | f :: fs -> separate semi_sep f fs
    in
    angles fields

  and pp_class ps name args =
    let name = sharp ++ Longident.pp name in
    match args with
    | [] -> name
    | x :: xs -> pp_params ps x xs ^/^ name

  and pp_alias ps ct alias =
    let ct = pp ps ct in
    let alias = pp_var ~loc:alias.loc alias.txt in
    let as_ = token_between ct alias "as" in
    (* TODO: hang & ident one linebreak *)
    let doc = ct ^/^ as_ ^/^ alias in
    Printing_stack.parenthesize ps doc

  and pp_variant fields closed present =
        (* [ `A|`B ]         (flag = Closed; labels = None)
           [> `A|`B ]        (flag = Open;   labels = None)
           [< `A|`B ]        (flag = Closed; labels = Some [])
           [< `A|`B > `X `Y ](flag = Closed; labels = Some ["X";"Y"])
         *)
    let le_caca =
      match closed, present with
      | Closed, None ->
        (* FIXME: this will do the breaking randomly. Take inspiration from what
           was done in odoc. *)
        let sep = break 1 ^^ group (pipe ^^ break 1) in
        hang 0 (separate_map sep Row_field.pp fields)
      | _, _ ->
        (* FIXME *)
        assert false
    in
    group (
      brackets (
        le_caca
      )
    )

  and pp_poly vars ct =
    (* FIXME: doesn't look right. *)
    let ct = pp [] ct in
    match vars with
    | [] -> ct
    | vars ->
      prefix ~indent:2 ~spaces:1
        (* FIXME: do I need to group here? *)
        ((separate_map space (fun { Location.txt; _ } -> pp_var txt) vars) ^^ dot)
        ct

  and pp_package pkg =
    parens (module_ ^/^ Package_type.pp pkg)

  let () = Constructor_decl.pp_core_type := pp
end

and Object_field : sig
  val pp : object_field -> document
end = struct
  let pp_desc = function
    | Otag (name, ct) -> string name.txt ^^ colon ^/^ Core_type.pp [] ct
    | Oinherit ct -> Core_type.pp [] ct

  let pp { pof_desc; pof_attributes; _ } =
    let desc = pp_desc pof_desc in
    Attribute.attach_to_item desc pof_attributes
end

and Package_type : sig
  val pp : package_type -> document
end = struct
  let pp (lid, constrs) =
    let lid = Longident.pp lid in
    match constrs with
    | [] -> lid
    | _ -> group (lid ^/^ !^"with" ^/^ !^"TODO")
end

and Row_field : sig
  val pp : row_field -> document
end = struct
  let pp_desc = function
    | Rinherit ct -> Core_type.pp [] ct
    | Rtag (tag, true, []) -> Polymorphic_variant_tag.pp tag
    | Rtag (tag, has_empty_constr, params) ->
      let sep = break 1 ^^ ampersand ^^ break 1 in
      let params = separate_map sep (Core_type.pp [ Row_field ]) params in
      let params =
        if has_empty_constr then
          sep ^^ params
        else
          break 1 ^^ params
      in
      Polymorphic_variant_tag.pp tag.txt ^/^ of_ ^^ params

  let pp { prf_desc; prf_attributes; _ } =
    let desc = pp_desc prf_desc in
    Attribute.attach_to_item desc prf_attributes
end

and Pattern : sig
  val pp : Printing_stack.t -> pattern -> document
end = struct
  let rec pp ps { ppat_desc; ppat_attributes; _ } =
    let ps = Printing_stack.Pattern ppat_desc :: ps in
    let desc = pp_desc ps ppat_desc in
    Attribute.attach_to_item desc ppat_attributes

  and pp_alias ps pat alias =
    nest 2 (pp ps pat ^/^ as_ ^/^ string alias.txt)

  and pp_interval c1 c2 =
    Constant.pp c1 ^/^ dotdot ^/^ Constant.pp c2

  (* FIXME? nest on the outside, not in each of them. *)

  and pp_tuple ps lst =
    let doc =
      nest 2 (
        separate_map (comma ^^ break 1) (pp ps) lst
      )
    in
    Printing_stack.parenthesize ps doc

  and pp_list_literal elts =
    let elts = List.map (pp []) elts in
    List_like.pp
      ~formatting:Wrap (* TODO: add an option *)
      ~left:lbracket ~right:rbracket
      elts

  and pp_cons ps hd tl =
    let ps = Printing_stack.top_is_op ~on_left:true "::" ps in
    let hd = pp ps hd in
    let ps = Printing_stack.top_is_op ~on_left:false "::" ps in
    let tl = pp ps tl in
    let doc = infix ~indent:2 ~spaces:1 !^"::" hd tl in
    Printing_stack.parenthesize ps doc

  and pp_construct ps name arg_opt =
    let name = Longident.pp name in
    match arg_opt with
    | None -> name
    | Some p ->
      let doc = prefix ~indent:2 ~spaces:1 name (pp ps p) in
      Printing_stack.parenthesize ps doc

  and pp_variant ps tag arg_opt =
    let tag = Polymorphic_variant_tag.pp tag in
    match arg_opt with
    | None -> tag
    | Some p -> 
      let arg = pp ps p in
      Printing_stack.parenthesize ps (tag ^/^ arg)

  and pp_record_field ps (lid, pat) =
    let field = Longident.pp lid in
    group (
      match pat.ppat_desc with
      | Ppat_var v when (Long_ident.last lid).txt = v.txt -> field
      | _ ->
        group (field ^/^ equals) ^^
        nest 2 (break 1 ^^ pp ps pat)
    )

  and pp_record ps pats closed =
    let fields = List.map (pp_record_field ps) pats in
    let extra_fields = match closed with Closed -> [] | Open -> [underscore] in
    List_like.pp
      ~formatting:!Options.Record.pattern
      ~left:lbrace ~right:rbrace
      (fields @ extra_fields)

  and pp_array ps pats =
    let pats = List.map (pp ps) pats in
    (* TODO: add an option *)
    List_like.pp ~formatting:Wrap
      ~left:(lbracket ^^ pipe) ~right:(pipe ^^ rbracket) pats

  and pp_or ps p1 p2 =
    let p1 =
      let ps = Printing_stack.top_is_op ~on_left:true "|" ps in
      pp ps p1
    in
    let p2 = pp ps p2 in
    let or_ = p1 ^/^ pipe ^^ space ^^ p2 in
    Printing_stack.parenthesize ps or_

  and pp_constraint p ct =
    parens (pp [] p ^/^ colon ^/^ Core_type.pp [] ct)

  and pp_type typ =
    sharp ^^ Longident.pp typ

  and pp_lazy ps p =
    Printing_stack.parenthesize ps (lazy_ ^/^  pp ps p)

  and pp_unpack mod_name ct =
    let constraint_ =
      match ct with
      | None -> empty
      | Some pkg -> break 1 ^^ colon ^/^ Package_type.pp pkg
    in
    parens (module_ ^/^ module_name mod_name.txt ^^ constraint_)

  and pp_exception ps p =
    exception_ ^/^ pp ps p

  and pp_open lid p =
    Longident.pp lid ^^ dot ^^ parens (break 0 ^^ pp [] p)

  and pp_desc ps = function
    | Ppat_any -> underscore
    | Ppat_var v -> string v.txt
    | Ppat_alias (pat, alias) -> pp_alias ps pat alias
    | Ppat_constant c -> Constant.pp c
    | Ppat_interval (c1, c2) -> pp_interval c1 c2
    | Ppat_tuple pats -> pp_tuple ps pats
    | Ppat_construct (name, arg) -> pp_construct ps name arg
    | Ppat_list_lit pats -> pp_list_literal pats
    | Ppat_cons (hd, tl) -> pp_cons ps hd tl
    | Ppat_variant (tag, arg) -> pp_variant ps tag arg
    | Ppat_record (pats, closed) -> pp_record ps pats closed
    | Ppat_array pats -> pp_array ps pats
    | Ppat_or (p1, p2) -> pp_or ps p1 p2
    | Ppat_constraint (p, ct) -> pp_constraint p ct
    | Ppat_type pt -> pp_type pt
    | Ppat_lazy p -> pp_lazy ps p
    | Ppat_unpack (name, typ) -> pp_unpack name typ
    | Ppat_exception p -> pp_exception ps p
    | Ppat_extension ext -> Extension.pp Item ext
    | Ppat_open (lid, p) -> pp_open lid p
end

and Application : sig
  val pp : Printing_stack.t -> expression -> (arg_label * expression) list ->
    document
end = struct
  let argument ps (lbl, exp) =
    let suffix lbl =
      match exp.pexp_desc with
      | Pexp_ident Lident id when lbl = id.txt -> empty
      | _ -> colon ^^ Expression.pp ps exp
    in
    match lbl with
    | Nolabel -> Expression.pp ps exp
    | Labelled lbl -> tilde ^^ string lbl ^^ suffix lbl
    | Optional lbl -> qmark ^^ string lbl ^^ suffix lbl

  let simple_apply ps exp args =
    let exp = Expression.pp ps exp in
    let args = separate_map (break 1) (argument ps) args in
    let doc = prefix ~indent:2 ~spaces:1 exp args in
    Printing_stack.parenthesize ps doc

  let prefix_op ps (exp, op) = function
    | (Nolabel, fst_arg) :: args ->
      let ps = Printing_stack.Prefix_op :: List.tl ps in
      let op = string op in
      let fst_arg = Expression.pp ps fst_arg in
      let args = separate_map (break 1) (argument ps) args in
      let doc = prefix ~indent:2 ~spaces:1 (op ^^ fst_arg) args in
      Printing_stack.parenthesize ps doc
    | args ->
      simple_apply ps exp args

  let infix_op ps (exp, op) = function
    | [ (Nolabel, fst); (Nolabel, snd) ] ->
      let ps = Printing_stack.top_is_op ~on_left:true op ps in
      let fst = Expression.pp ps fst in
      let ps = Printing_stack.top_is_op ~on_left:false op ps in
      let snd = Expression.pp ps snd in
      let doc = infix ~indent:2 ~spaces:1 (string op) fst snd in
      Printing_stack.parenthesize ps doc
    | args ->
      simple_apply ps exp args

  let classify_fun exp =
    match exp.pexp_desc with
    | Pexp_ident Lident s when s.txt <> "" -> Ident_class.classify s.txt
    | _ -> Normal

  let pp ps exp args =
    match classify_fun exp with
    | Normal -> simple_apply ps exp args
    | Prefix_op op -> prefix_op ps (exp, op) args
    | Infix_op op -> infix_op ps (exp, op) args

end

and Expression : sig
  val pp : Printing_stack.t -> expression -> document
end = struct
  let rec pp ps { pexp_desc; pexp_attributes; _ } =
    let desc =
      group (pp_desc (Printing_stack.Expression pexp_desc :: ps) pexp_desc)
    in
    Attribute.attach_to_item desc pexp_attributes

  and pp_desc ps = function
    | Pexp_ident id -> pp_ident id
    | Pexp_constant c -> Constant.pp c
    | Pexp_let (rf, vbs, body) -> pp_let ps rf vbs body
    | Pexp_function cases -> pp_function ps cases
    | Pexp_fun (params, exp) ->
      pp_fun ps params exp
    | Pexp_apply (expr, args) -> Application.pp ps expr args
    | Pexp_match (arg, cases) -> pp_match ps arg cases
    | Pexp_try (arg, cases) -> pp_try ps arg cases
    | Pexp_tuple exps -> pp_tuple ps exps
    | Pexp_list_lit exps -> pp_list_literal ps exps
    | Pexp_cons (hd, tl) -> pp_cons ps hd tl
    | Pexp_construct (lid, arg) -> pp_construct ps lid arg
    | Pexp_variant (tag, arg) -> pp_variant ps tag arg
    | Pexp_record (fields, exp) -> pp_record ps fields exp
    | Pexp_field (exp, fld) -> pp_field ps exp fld
    | Pexp_setfield (exp, fld, val_) -> pp_setfield ps exp fld val_
    | Pexp_array elts -> pp_array ps elts
    | Pexp_ifthenelse (cond, then_, else_) ->
      pp_if_then_else ps cond then_ else_
    | Pexp_sequence (e1, e2) -> pp_sequence ps e1 e2
    | Pexp_while (cond, body) -> pp_while cond body
    | Pexp_for (it, start, stop, dir, body) -> pp_for it start stop dir body
    | Pexp_constraint (e, ct) -> pp_constraint e ct
    | Pexp_coerce (e, ct_start, ct) -> pp_coerce e ct_start ct
    | Pexp_send (e, meth) -> pp_send ps e meth
    | Pexp_new lid -> pp_new lid
    | Pexp_setinstvar (lbl, exp) -> pp_setinstvar ps lbl exp
    | Pexp_override fields -> pp_override fields
    | Pexp_letmodule (name, mb, body) -> pp_letmodule ps name mb body
    | Pexp_letexception (exn, exp) -> pp_letexception ps exn exp
    | Pexp_assert exp -> pp_assert ps exp
    | Pexp_lazy exp -> pp_lazy ps exp
    | Pexp_object cl -> pp_object cl
    | Pexp_pack (me, pkg) -> pp_pack me pkg
    | Pexp_open (lid, exp) -> pp_open lid exp
    | Pexp_letopen (od, exp) -> pp_letopen ps od exp
    | Pexp_letop letop -> pp_letop letop
    | Pexp_extension ext -> Extension.pp Item ext
    | Pexp_unreachable -> dot
      (* TODO *)
    | Pexp_array_get _
    | Pexp_array_set _
    | Pexp_string_get _
    | Pexp_string_set _
    | Pexp_bigarray_get _
    | Pexp_bigarray_set _
    | Pexp_dotop_get _
    | Pexp_dotop_set _
      ->
      assert false

  and pp_ident id =
    (* FIXME: move the grouping to [Longident.pp] *)
    group (Longident.pp id)

  and pp_let ps rf vbs body =
    let vbs =
      List.mapi (fun i vb ->
        let binding = Value_binding.pp Attached_to_item vb in
        let keyword = if i = 0 then let_ ^^ rec_flag rf else and_ in
        Binding.pp ~keyword binding
      ) vbs
    in
    let vbs = separate hardline vbs in
    let body =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps body
    in
    Printing_stack.parenthesize ps (group (vbs ^/^ in_) ^^ hardline ^^ body)

  and rec_flag = function
    | Recursive -> string " rec"
    | Nonrecursive -> empty

  and case ps { pc_lhs; pc_guard; pc_rhs } =
    let lhs = Pattern.pp [] pc_lhs in
    let rhs = pp ps pc_rhs in
    let lhs =
      match pc_guard with
      | None -> lhs
      | Some guard ->
        let guard = pp ps guard in
        lhs ^/^ group (!^"when" ^/^ guard)
    in
    let lhs = group (lhs ^^ nest 2 (break 1 ^^ arrow)) in
    match !Options.Cases.body_on_separate_line with
    | Always -> lhs ^^ nest !Options.Cases.body_indent (hardline ^^ rhs)
    | When_needed -> prefix ~indent:!Options.Cases.body_indent ~spaces:1 lhs rhs

  and cases ps case_list =
    let cases = separate_map (break 1 ^^ pipe ^^ space) (case ps) case_list in
    let prefix = ifflat empty (hardline ^^ pipe) in
    prefix ^^ space ^^ cases

  and pp_function ps case_list =
    let doc = !^"function" ^^ (cases ps) case_list in
    Printing_stack.parenthesize ps doc

  and fun_ ~args ~body =
    prefix ~indent:2 ~spaces:1
      (group ((prefix ~indent:2 ~spaces:1 !^"fun" args) ^/^ arrow))
      body

  and pp_fun ps params exp =
    let body = pp ps exp in
    let args = left_assoc_map ~sep:empty ~f:Fun_param.pp params in
    let doc = fun_ ~args ~body in
    Printing_stack.parenthesize ps doc

  and pp_match ps arg case_list =
    let arg = pp [] arg in
    let cases = cases ps case_list in
    let doc =
      group (
        string "match" ^^
        nest 2 (break 1 ^^ arg) ^/^
        string "with"
      ) ^^ cases
    in
    Printing_stack.parenthesize ps 
      ~situations:!Options.Match.parenthesing_situations
      ~style:!Options.Match.parens_style
      doc

  and pp_try ps arg case_list =
    let arg = pp [] arg in
    let cases = cases ps case_list in
    let doc =
      group (
        string "try" ^^
        nest 2 (break 1 ^^ arg)
      ) ^/^
      string "with" ^^
      cases
    in
    Printing_stack.parenthesize ps doc

  and pp_tuple ps exps =
    let doc =
      group (separate_map (comma ^^ break 1) (pp ps) exps)
    in
    Printing_stack.parenthesize ps doc

  and pp_construct ps lid arg_opt =
    let name = Longident.pp lid in
    let arg  = optional (pp ps) arg_opt in
    let doc  = prefix ~indent:2 ~spaces:1 name arg in
    Printing_stack.parenthesize ps doc

  and pp_cons ps hd tl =
    let ps = Printing_stack.top_is_op ~on_left:true "::" ps in
    let hd = Expression.pp ps hd in
    let ps = Printing_stack.top_is_op ~on_left:false "::" ps in
    let tl = Expression.pp ps tl in
    let doc = infix ~indent:2 ~spaces:1 !^"::" hd tl in
    Printing_stack.parenthesize ps doc

  and pp_list_literal ps elts =
    let elts = List.map (pp ps) elts in
    List_like.pp
      ~formatting:Wrap (* TODO: add an option *)
      ~left:lbracket ~right:rbracket
      elts

  and pp_variant ps tag arg_opt =
    let tag = Polymorphic_variant_tag.pp tag in
    let arg  = optional (pp ps) arg_opt in
    let doc  = prefix ~indent:2 ~spaces:1 tag arg in
    Printing_stack.parenthesize ps doc

  and record_field (lid, exp) =
    let fld = Longident.pp lid in
    group (
      match exp.pexp_desc with
      | Pexp_ident Lident id when (Long_ident.last lid).txt = id.txt -> fld
      | _ ->
        group (fld ^/^ equals) ^^
        nest 2 (break 1 ^^ pp [ Printing_stack.Record_field ] exp)
    )

  and pp_record ps fields updated_record =
    let fields = List.map record_field fields in
    let update =
      match updated_record with
      | None -> empty
      | Some e -> group (group (break 1 ^^ pp ps e) ^/^ !^"with")
    in
    List_like.pp
      ~formatting:!Options.Record.expression
      ~left:(group (lbrace ^^ update))
      ~right:rbrace
      fields

  and pp_field ps re fld =
    let record = pp ps re in
    let field = Longident.pp fld in
    flow (break 0) [
      record; dot; field
    ]

  and pp_setfield ps re fld val_ =
    let field = pp_field ps re fld in
    let value = pp (List.tl ps) val_ in
    prefix ~indent:2 ~spaces:1
      (group (field ^/^ larrow))
      value

  and pp_array ps elts =
    let elts = List.map (pp ps) elts in
    (* TODO: add an option *)
    List_like.pp ~formatting:Wrap
      ~left:(lbracket ^^ pipe) ~right:(pipe ^^ rbracket) elts

  (* FIXME: change ast to present n-ary [if]s *)
  and pp_if_then_else ps cond then_ else_opt =
    let cond = pp [] cond in
    let then_ = pp ps then_ in
    let else_ =
      optional (fun e ->
        break 1 ^^ !^"else" ^^
        nest 2 (break 1 ^^ pp ps e)
      ) else_opt
    in
    group (
      group (
        string "if" ^^
        nest 2 (break 1 ^^ cond) ^/^
        string "then"
      ) ^^ 
      nest 2 (break 1 ^^ then_) ^^
      else_
    )

  and pp_sequence ps e1 e2 =
    let e1 = pp ps e1 in
    let e2 =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps e2
    in
    let doc = e1 ^^ semi ^/^ e2 in
    Printing_stack.parenthesize ps doc

  and pp_while cond body =
    let cond = pp [] cond in
    let body = pp [] body in
    group (
      group (
        string "while" ^^
        nest 2 (break 1 ^^ cond) ^/^
        string "do"
      ) ^^
      nest 2 (break 1 ^^ body) ^/^
      string "done"
    ) 

  and pp_for it start stop dir body =
    let it = Pattern.pp [ Printing_stack.Value_binding ] it in
    let start = pp [] start in
    let stop = pp [] stop in
    let dir =
      match dir with
      | Upto -> !^"to"
      | Downto -> !^"downto"
    in
    let body = pp [] body in
    group (
      group (
        string "for" ^^
        nest 2 (
          break 1 ^^
          group (it ^/^ equals ^/^ start) ^/^
          dir ^/^
          stop
        ) ^/^
        string "do"
      ) ^^
      nest 2 (break 1 ^^ body) ^/^
      string "done"
    )

  and pp_constraint exp ct =
    let exp = pp [] exp in
    let ct = Core_type.pp [] ct in
    group (parens (exp ^/^ colon ^/^ ct))

  and pp_coerce exp ct_start ct =
    let exp = pp [] exp in
    let ct_start =
      optional (fun ct -> break 1 ^^ colon ^/^ Core_type.pp [] ct) ct_start
    in
    let ct = Core_type.pp [] ct in
    group (parens (group (exp ^^ ct_start) ^/^ !^":>" ^/^  ct))

  and pp_send ps exp met =
    let exp =
      let ps = Printing_stack.top_is_op ~on_left:true "#" ps in
      pp ps exp
    in
    let met = string met.txt in
    let doc = flow (break 0) [ exp; sharp; met ] in
    Printing_stack.parenthesize ps doc

  and pp_new lid =
    Longident.pp lid

  and pp_setinstvar ps lbl exp =
    let lbl = string lbl.txt in
    let exp = pp (List.tl ps) exp in
    (* FIXME: parens? *)
    lbl ^/^ larrow ^/^ exp

  and obj_field_override (lbl, exp) =
    let fld = string lbl.txt in
    let exp = pp [ Printing_stack.Record_field ] exp in
    fld ^/^ equals ^/^ exp

  and pp_override fields =
    let fields = separate_map (semi ^^ break 1) obj_field_override fields in
    (* FIXME: breaking, indent, blablabla *)
    braces (angles fields)

  and pp_letmodule ps name (params, typ, mexp) expr =
    let binding = Module_binding.pp_raw name params typ mexp [] in
    let bind = Binding.Module.pp ~keyword:(group (let_ ^/^ module_)) binding in
    let expr =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps expr
    in
    let doc = bind ^/^ in_ ^/^ expr in
    Printing_stack.parenthesize ps doc

  and pp_letexception ps exn exp =
    let exn = Constructor_decl.pp_extension exn in
    let exp =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps exp
    in
    let doc =
      group (prefix ~indent:2 ~spaces:1 !^"let exception"
               (group (exn ^/^ !^"in")))
      ^^ exp
    in
    Printing_stack.parenthesize ps doc

  and pp_assert ps exp =
    let exp = pp ps exp in
    prefix ~indent:2 ~spaces:1 !^"assert" exp

  and pp_lazy ps exp =
    let exp = pp ps exp in
    let doc = lazy_ ^/^ exp in
    Printing_stack.parenthesize ps doc

  and pp_object cl =
    let cl = Class_structure.pp cl in
    group (
      string "object" ^^
      nest 2 (break 1 ^^ cl) ^/^
      string "end"
    )


  and pp_pack me pkg =
    let me = Module_expr.pp me in
    let constraint_ =
      match pkg with
      | None -> empty
      | Some pkg -> break 1 ^^ colon ^/^ Package_type.pp pkg
    in
    parens (module_ ^/^ me ^^ constraint_)

  and pp_open lid exp =
    let lid = Longident.pp lid in
    let exp = pp [] exp in
    lid ^^ dot ^^ parens (break 0 ^^ exp ^^ break 0)

  and pp_letopen ps od exp =
    let od = Open_declaration.pp Attached_to_item od in
    let exp =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps exp
    in
    let doc = !^"let " ^^ od ^^ !^" in" ^/^ exp in
    Printing_stack.parenthesize ps doc

  and pp_letop _ =
    assert false
end

and Fun_param : sig
  val pp : fun_param -> document
end = struct
  let term lbl default pat =
    let suffix lbl =
      match pat.ppat_desc with
      | Ppat_var v when lbl = v.txt -> empty
      | _ -> colon ^^ Pattern.pp [ Printing_stack.Value_binding ] pat
    in
    match lbl with
    | Nolabel -> Pattern.pp [ Printing_stack.Value_binding ] pat
    | Labelled lbl -> tilde ^^ string lbl ^^ suffix lbl
    | Optional lbl ->
      match default with
      | None -> qmark ^^ string lbl ^^ suffix lbl
      | Some def ->
        (* TODO: punning *)
        let pat = Pattern.pp [] pat in
        let exp = Expression.pp [ Printing_stack.Value_binding ] def in
        qmark ^^ string lbl ^^ colon ^^ parens (group (pat ^/^ equals ^/^ exp))

  let newtype typ =
    parens (!^"type" ^/^ string typ.txt)

  let pp = function
    | Term (lbl, default, pat) -> group (term lbl default pat)
    | Type typ -> group (newtype typ)
end

and Value_binding : sig
  val pp : Attribute.kind -> value_binding -> Binding.t
end = struct

  let pp attr_kind
      { pvb_pat; pvb_params; pvb_type; pvb_expr; pvb_attributes; _ } =
    let pat = Pattern.pp [ Printing_stack.Value_binding ] pvb_pat in
    let params = List.map Fun_param.pp pvb_params in
    let constr, coerce = pvb_type in
    let constr = Option.map (Core_type.pp [ Value_binding ]) constr in
    let coerce = Option.map (Core_type.pp [ Value_binding ]) coerce in
    let rhs = Expression.pp [] pvb_expr in
    let rhs = Attribute.attach attr_kind rhs pvb_attributes in
    { Binding.lhs = pat; params; constr; coerce; rhs }
end

and Module_expr : sig
  val pp : module_expr -> document
end = struct
  let rec pp { pmod_desc; pmod_attributes; _ } =
    let doc = pp_desc pmod_desc in
    Attribute.attach_to_item doc pmod_attributes

  and pp_desc = function
    | Pmod_ident lid -> Longident.pp lid
    | Pmod_structure str -> pp_structure str
    | Pmod_functor (Unit, me) -> pp_generative_functor me
    | Pmod_functor (Named (param, mty), me) ->
      pp_applicative_functor param mty me
    | Pmod_apply (me1, me2) -> pp_apply me1 me2
    | Pmod_constraint (me, mty) -> pp_constraint me mty
    | Pmod_unpack e -> pp_unpack e
    | Pmod_extension ext -> Extension.pp Item ext

  and pp_structure str =
    let str = Structure.pp str in
    group (
      string "struct" ^^
      nest 2 (break 1 ^^ str) ^/^
      string "end"
    )

  and pp_generative_functor me =
    let me = pp me in
    !^"functor" ^/^ !^"()" ^/^ arrow ^/^ me

  and pp_applicative_functor param mty me =
    let param = module_name param.txt in
    let mty = Module_type.pp mty in
    let me = pp me in
    !^"functor" ^/^ parens (param ^/^ colon ^/^ mty) ^/^ arrow ^/^ me

  and pp_apply me1 me2 =
    let me1 = pp me1 in
    let me2 = pp me2 in
    me1 ^^ break 0 ^^ parens me2

  and pp_constraint me mty =
    let me = pp me in
    let mty = Module_type.pp mty in
    parens (me ^/^ colon ^/^ mty)

  and pp_unpack exp =
    let exp = Expression.pp [ Unpack ] exp in
    parens (!^"val" ^^ exp)
end

and Module_type : sig
  val pp : module_type -> document
end = struct
  let rec pp { pmty_desc; pmty_attributes; _ } =
    Attribute.attach_to_item (pp_desc pmty_desc) pmty_attributes

  and pp_desc = function
    | Pmty_ident lid -> Longident.pp lid
    | Pmty_signature sg -> pp_signature sg
    | Pmty_functor (Unit, mty) -> pp_generative_functor mty
    | Pmty_functor (Named (param, pmty), mty) ->
      pp_applicative_functor param pmty mty
    | Pmty_with (mty, cstrs) -> pp_with mty cstrs
    | Pmty_typeof me -> pp_typeof me
    | Pmty_extension ext -> Extension.pp Item ext
    | Pmty_alias _ -> assert false (* shouldn't be produced by the parser. *)

  and pp_signature sg =
    let sg = Signature.pp sg in
    group (
      string "sig" ^^
      nest 2 (break 1 ^^ sg) ^/^
      string "end"
    )

  and pp_generative_functor mty =
    let me = pp mty in
    !^"functor" ^/^ !^"()" ^/^ arrow ^/^ me

  and pp_applicative_functor param pmty mty =
    let param = module_name param.txt in
    let pmty = pp pmty in
    let mty = pp mty in
    !^"functor" ^/^ parens (param ^/^ colon ^/^ pmty) ^/^ arrow ^/^ mty

  (* TODO *)
  and pp_with mty _cstrs =
    let mty = pp mty in
    mty ^/^ !^"with <CSTRS>" 

  and pp_typeof exp =
    let me = Module_expr.pp exp in
    flow (break 1) [
      module_; !^"type"; of_; me
    ]

end

and Module_binding : sig
  val pp_raw
    :  string option loc
    -> functor_parameter list
    -> module_type option
    -> module_expr
    -> attributes
    -> Binding.Module.t

  val pp : module_binding -> Binding.Module.t
end = struct
  let param = function
    | Unit -> !^"()"
    | Named (name, mty) ->
      group (
        parens (
          prefix ~indent:2 ~spaces:1
            (group (module_name name.txt ^/^ colon))
            (Module_type.pp mty)
        )
      )

  let pp_mty = function
    | None -> Binding.Module.None
    | Some ({ pmty_desc; pmty_attributes; _ } as mty) ->
      match pmty_desc, pmty_attributes with
      | Pmty_signature sg, [] -> Binding.Module.Sig (Signature.pp sg)
      | _ -> Binding.Module.Mty (Module_type.pp mty)

  let pp_me ({ pmod_desc; pmod_attributes; _ } as me) =
    match pmod_desc, pmod_attributes with
    | Pmod_structure str, [] -> Binding.Module.Struct (Structure.pp str)
    | _ -> Binding.Module.Expr (Module_expr.pp me)

  let pp_raw name params mty me attrs =
    let name = module_name name.txt in
    let params = List.map param params in
    let constr = pp_mty mty in
    let expr = pp_me me in
    let attributes =
      separate_map (break 0) (Attribute.pp Attached_to_structure_item) attrs
    in
    { Binding.Module. name; params; constr; expr; attributes }

  let pp { pmb_name; pmb_params; pmb_type; pmb_expr; pmb_attributes; _ } =
    let binding = pp_raw pmb_name pmb_params pmb_type pmb_expr pmb_attributes in
    let expr = binding.expr in
    { binding with expr }
end

and Module_type_declaration : sig
  val pp : module_type_declaration -> document
end = struct
  let pp { pmtd_name; pmtd_type; pmtd_attributes; _ } =
    let kw = !^"module type" in
    let name = string pmtd_name.txt in
    let doc =
      match pmtd_type with
      | None -> kw ^/^ name
      | Some mty ->
        let typ = Module_type.pp mty in
        Binding.pp_simple ~keyword:kw name typ
    in
    Attribute.attach_to_top_item doc pmtd_attributes
end

and Structure : sig
  val pp : structure -> document
end = struct
  let pp_eval exp attrs =
    let exp = Expression.pp [] exp in
    Attribute.attach_to_top_item exp attrs

  and rec_flag = function
    | Recursive -> string " rec"
    | Nonrecursive -> empty

  let pp_value rf vbs =
    let vbs =
      List.mapi (fun i vb ->
        let binding = Value_binding.pp Attached_to_structure_item vb in
        let keyword = if i = 0 then let_ ^^ rec_flag rf else and_ in
        Binding.pp ~keyword binding
      ) vbs
    in
    separate (twice hardline) vbs

  let pp_module mb =
    Binding.Module.pp ~keyword:module_ (Module_binding.pp mb)

  let pp_recmodule mbs =
    let mbs =
      List.mapi (fun i mb ->
        let keyword = if i = 0 then group (module_ ^/^ !^"rec") else and_ in
        Binding.Module.pp ~keyword (Module_binding.pp mb)
      ) mbs
    in
    separate (twice hardline) mbs

  let pp_include { pincl_mod; pincl_attributes; _ } =
    let incl = Module_expr.pp pincl_mod in
    Attribute.attach_to_top_item 
      (group (!^"include" ^/^ incl))
      pincl_attributes

  let pp_extension ext attrs =
    let ext = Extension.pp Structure_item ext in
    Attribute.attach_to_top_item ext attrs

  let pp_item ({ pstr_desc; _ } as _item) =
    match pstr_desc with
    | Pstr_eval (e, attrs) -> pp_eval e attrs
    | Pstr_value (rf, vbs) -> pp_value rf vbs
    | Pstr_primitive vd -> Value_description.pp vd
    | Pstr_type (rf, tds) -> Type_declaration.pp_decl rf tds
    | Pstr_typext te -> Type_extension.pp te
    | Pstr_exception exn -> Type_exception.pp exn
    | Pstr_module mb -> pp_module mb
    | Pstr_recmodule mbs -> pp_recmodule mbs
    | Pstr_modtype mtd -> Module_type_declaration.pp mtd
    | Pstr_open od -> Open_declaration.pp Attached_to_structure_item od
    | Pstr_class _ -> assert false
    | Pstr_class_type _ -> assert false
    | Pstr_include incl -> pp_include incl
    | Pstr_attribute attr -> Attribute.pp Free_floating attr
    | Pstr_extension (ext, attrs) -> pp_extension ext attrs

  let pp = separate_map (twice hardline) pp_item
end

and Signature : sig
  val pp : signature -> document
end = struct
  let pp_extension ext attrs =
    let ext = Extension.pp Structure_item ext in
    Attribute.attach_to_top_item ext attrs

  let pp_include { pincl_mod; pincl_attributes; _ } =
    let incl = Module_type.pp pincl_mod in
    Attribute.attach_to_top_item 
      (group (!^"include" ^/^ incl))
      pincl_attributes

  let pp_item { psig_desc; _ } =
    match psig_desc with
    | Psig_value vd -> Value_description.pp vd
    | Psig_type (rf, decls) -> Type_declaration.pp_decl rf decls
    | Psig_typesubst decls -> Type_declaration.pp_subst decls
    | Psig_typext te -> Type_extension.pp te
    | Psig_exception exn -> Type_exception.pp exn
    | Psig_modtype mtd -> Module_type_declaration.pp mtd
    | Psig_open od -> Open_description.pp od
    | Psig_include incl -> pp_include incl
    | Psig_attribute attr -> Attribute.pp Free_floating attr
    | Psig_extension (ext, attrs) -> pp_extension ext attrs
    | _ -> assert false

  let pp = separate_map (twice hardline) pp_item
end

and Value_description : sig
  val pp : value_description -> document
end = struct
  let pp vd =
    let name = string vd.pval_name.txt in
    let ctyp = Core_type.pp [] vd.pval_type in
    let prim =
      match vd.pval_prim with
      | [] -> empty
      | prims ->
        let prims = separate_map (break 1) (fun p -> dquotes (string p)) prims in
        break 1 ^^ group (equals ^/^ prims)
    in
    let doc =
      prefix ~indent:2 ~spaces:1 (group (!^"val" ^/^ name))
        (colon ^^ ifflat space (twice space) ^^ ctyp ^^ prim)
    in
    Attribute.attach_to_top_item doc vd.pval_attributes
end

and Type_extension : sig
  val pp : type_extension -> document
end = struct
  let constructors cstrs =
    let cstrs =
      separate_map (break 1 ^^ pipe ^^ space)
        Constructor_decl.pp_extension cstrs
    in
    let prefix = ifflat empty (pipe ^^ space) in
    prefix ^^ cstrs

  let pp { ptyext_path; ptyext_params; ptyext_constructors; ptyext_private;
           ptyext_attributes; _ } =
    let path = Longident.pp ptyext_path in
    let params = Type_declaration.pp_params ptyext_params in
    let lhs = group (params ^^ path) in
    let constructors = constructors ptyext_constructors in
    let rhs =
      match ptyext_private with
      | Public -> constructors
      | Private -> group (!^"private" ^/^ constructors)
    in
    let rhs = Attribute.attach_to_top_item rhs ptyext_attributes in
    Binding.pp_simple ~keyword:!^"type" ~binder:!^"+=" lhs rhs
end

and Type_exception : sig
  val pp : type_exception -> document
end = struct
  let pp { ptyexn_constructor; ptyexn_attributes; _ } =
    let cstr = Constructor_decl.pp_extension ptyexn_constructor in
    let doc = group (prefix ~spaces:1 ~indent:2 !^"exception" cstr) in
    Attribute.attach_to_top_item doc ptyexn_attributes
end

and Type_declaration : sig
  val pp : type_declaration -> document * document

  val pp_params : (core_type * variance) list -> document

  val pp_decl : rec_flag -> type_declaration list -> document

  val pp_subst : type_declaration list -> document
end = struct
  let pp_param (ct, var) =
    let ct = Core_type.pp [] ct in
    match var with
    | Invariant -> ct
    | Covariant -> plus ^^ ct
    | Contravariant -> minus ^^ ct

  let pp_params lst =
    match lst with
    | [] -> empty
    | [ x ] -> pp_param x ^^ break 1
    | _ -> parens (separate_map (comma ^^ break 1) pp_param lst) ^^ break 1

  let label_declaration { pld_name; pld_mutable; pld_type; pld_attributes; _ } =
    let mutable_ =
      match pld_mutable with
      | Mutable -> !^"mutable" ^^ break 1
      | Immutable -> empty
    in
    let name = string pld_name.txt in
    let typ  = Core_type.pp [] pld_type in
    let decl =
      group (
        nest 2 (
          group (mutable_ ^^ group (name ^/^ colon)) ^/^ typ
        )
      )
    in
    Attribute.attach_to_item decl pld_attributes

  let record lbl_decls =
    let lbls = separate_map (semi ^^ break 1) label_declaration lbl_decls in
    lbrace ^^
    nest 2 (break 1 ^^ lbls) ^/^
    rbrace

  let () = Constructor_decl.pp_record := record

  let variant cstrs =
    let cstrs =
      separate_map (break 1 ^^ pipe ^^ space)
        (fun c -> nest 2 (Constructor_decl.pp_decl c)) cstrs
    in
    let prefix = ifflat empty (pipe ^^ space) in
    prefix ^^ cstrs

  let type_kind = function
    | Ptype_abstract -> empty
    | Ptype_open -> dotdot
    | Ptype_record lbl_decls -> record lbl_decls
    | Ptype_variant cstrs -> variant cstrs 

  (* TODO: constraints *)
  let pp { ptype_name; ptype_params; ptype_cstrs = _; ptype_kind; ptype_private;
           ptype_manifest; ptype_attributes; _ } =
    let name = string ptype_name.txt in
    let params = pp_params ptype_params in
    let kind = type_kind ptype_kind in
    let manifest = optional (Core_type.pp []) ptype_manifest in
    let private_ =
      match ptype_private with
      | Private -> !^"private" ^^ break 1
      | Public -> empty
    in
    let lhs = group (params ^^ name) in
    let rhs =
      match ptype_manifest, ptype_kind with
      | Some _, Ptype_abstract -> private_ ^^ manifest
      | Some _, _ -> manifest ^/^ equals ^/^ private_ ^^ kind
      | None, _ -> private_ ^^ kind
    in
    let rhs = Attribute.attach_to_top_item rhs ptype_attributes in
    lhs, rhs

  let rec_flag = function
    | Recursive -> empty
    | Nonrecursive -> !^" nonrec "

  let pp_decl rf decls =
    let decls =
      List.mapi (fun i decl ->
        let lhs, rhs = pp decl in
        let keyword = if i = 0 then !^"type" ^^ rec_flag rf else and_ in
        Binding.pp_simple ~keyword lhs rhs
      ) decls
    in
    separate (twice hardline) decls

  let pp_subst decls =
    let binder = !^":=" in
    let decls =
      List.mapi (fun i decl ->
        let lhs, rhs = pp decl in
        let keyword = if i = 0 then !^"type" else and_ in
        Binding.pp_simple ~binder ~keyword lhs rhs
      ) decls
    in
    separate hardline decls
end

and Class_structure : sig
  val pp : class_structure -> document
end = struct
  let pp _ = assert false
end

and Open_description : sig
  val pp : open_description -> document
end = struct
  let pp { popen_expr; popen_override; popen_attributes; _ } =
    let expr = Longident.pp popen_expr in
    let over =
      match popen_override with
      | Override -> bang
      | _ -> empty
    in
    let opn = group (!^"open" ^^ over ^/^ expr) in
    Attribute.attach_to_top_item opn popen_attributes
end

and Open_declaration : sig
  val pp : Attribute.kind -> open_declaration -> document
end = struct
  let pp kind { popen_expr; popen_override; popen_attributes; _ } =
    let expr = Module_expr.pp popen_expr in
    let over =
      match popen_override with
      | Override -> bang
      | _ -> empty
    in
    let opn = group (!^"open" ^^ over ^/^ expr) in
    Attribute.attach kind opn popen_attributes
end
