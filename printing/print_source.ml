open Source_parsing
open Asttypes
open Source_tree

open Document
open struct type document = Document.t end

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
    | Prefix_op of string loc
    | Infix_op of string loc
    | Normal

  (* Refer to:
     http://caml.inria.fr/pub/docs/manual-ocaml/lex.html#sss:lex-ops-symbols *)
  let classify s =
    match s.txt with
    | "" -> assert false
    | ":=" | "or" | "&" | "&&" | "!=" | "mod" | "land" | "lor" | "lxor"
    | "lsl" | "lsr" | "asr" | "::" -> Infix_op s
    | _ ->
      match String.get s.txt 0 with
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
    match Ident_class.classify s with
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
    | Ptyp_package pkg -> pp_package ~loc pkg
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
        let sep = PPrint.(break 1 ^^ group (pipe ^^ break 1)) in
        hang 0 (
          separate_map sep ~f:Row_field.pp (List.hd fields) (List.tl fields)
        )
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
    | v :: vs ->
      let vars= separate_map space ~f:(fun v -> pp_var ~loc:v.loc v.txt) v vs in
      let dot = token_between vars ct "." in
      prefix ~indent:2 ~spaces:1
        (group (vars ^^ dot))
        ct

  and pp_package ~loc pkg =
    let module_ = string ~loc "module" in
    parens (module_ ^/^ Package_type.pp pkg)

  let () = Constructor_decl.pp_core_type := pp
end

and Object_field : sig
  val pp : object_field -> document
end = struct
  let pp_otag name ct =
    let name = str name in
    let ct = Core_type.pp [] ct in
    let colon = token_between name ct ":" in
    group (name ^^ colon) ^/^ ct

  let pp_desc = function
    | Otag (name, ct) -> pp_otag name ct
    | Oinherit ct -> Core_type.pp [] ct

  let pp { pof_desc; pof_attributes; _ } =
    let desc = pp_desc pof_desc in
    Attribute.attach_to_item desc pof_attributes
end

and Package_type : sig
  val pp : package_type -> document
end = struct
  let pp_constr (lid, ct) =
    (* FIXME: use [Binding.simple] *)
    concat (Longident.pp lid) (Core_type.pp [] ct)
      ~sep:PPrint.(break 1 ^^ !^"=" ^^ break 1)

  let pp (lid, constrs) =
    let lid = Longident.pp lid in
    match constrs with
    | [] -> lid
    | x :: xs ->
      let constrs =
        separate_map
          PPrint.(break 1 ^^ !^"and" ^^ break 1 ^^ !^"type" ^^ break 1)
          ~f:pp_constr x xs
      in
      let sep = PPrint.(break 1 ^^ !^"with" ^/^ !^"type") in
      group (concat lid constrs ~sep)
end

and Row_field : sig
  val pp : row_field -> document
end = struct
  let pp_params p ps =
    let sep = PPrint.(break 1 ^^ ampersand ^^ break 1) in
    separate_map sep ~f:(Core_type.pp [ Row_field ]) p ps

  let pp_desc = function
    | Rinherit ct -> Core_type.pp [] ct
    | Rtag (tag, has_empty_constr, []) ->
      assert (not has_empty_constr);
      Polymorphic_variant_tag.pp tag
    | Rtag (tag, has_empty_constr, p :: ps) ->
      let tag = Polymorphic_variant_tag.pp tag in
      let params = pp_params p ps in
      let of_params =
        let of_ = token_between tag params "of" in
        if has_empty_constr then
          let sep = PPrint.(break 1 ^^ ampersand ^^ break 1) in
          concat of_ ~sep params
        else
          of_ ^/^ params
      in
      tag ^/^ of_params

  let pp { prf_desc; prf_attributes; _ } =
    let desc = pp_desc prf_desc in
    Attribute.attach_to_item desc prf_attributes
end

and Pattern : sig
  val pp : Printing_stack.t -> pattern -> document
end = struct
  let rec pp ps { ppat_desc; ppat_attributes; ppat_loc; _ } =
    let ps = Printing_stack.Pattern ppat_desc :: ps in
    let desc = pp_desc ~loc:ppat_loc ps ppat_desc in
    Attribute.attach_to_item desc ppat_attributes

  and pp_alias ps pat alias =
    let pat = pp ps pat in
    let alias = str alias in
    let as_ = token_between pat alias "as" in
    nest 2 (pat ^/^ as_ ^/^ alias)

  and pp_interval c1 c2 =
    let c1 = Constant.pp ~loc:c1.loc c1.txt in
    let c2 = Constant.pp ~loc:c2.loc c2.txt in
    let dotdot = token_between c1 c2 ".." in
    c1 ^/^ dotdot ^/^ c2

  (* FIXME? nest on the outside, not in each of them. *)

  and pp_tuple ps lst =
    let doc =
      nest 2 (
        separate_map PPrint.(comma ^^ break 1) ~f:(pp ps)
          (List.hd lst) (List.tl lst)
      )
    in
    Printing_stack.parenthesize ps doc

  and pp_list_literal ~loc elts =
    let elts = List.map (pp []) elts in
    List_like.pp ~loc
      ~formatting:Wrap (* TODO: add an option *)
      ~left:lbracket ~right:rbracket
      elts

  and pp_cons ps hd tl =
    let ps = Printing_stack.top_is_op ~on_left:true "::" ps in
    let hd = pp ps hd in
    let ps = Printing_stack.top_is_op ~on_left:false "::" ps in
    let tl = pp ps tl in
    let cons = token_between hd tl "::" in
    let doc = infix ~indent:2 ~spaces:1 cons hd tl in
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
        let pat = pp ps pat in
        let equals = token_between field pat "=" in
        group (field ^/^ equals) ^^
        nest 2 (break_before pat)
    )

  and pp_record ~loc ps pats closed =
    let fields = List.map (pp_record_field ps) pats in
    let extra_fields =
      match closed with
      | OClosed -> []
      | OOpen loc -> [underscore ~loc]
    in
    List_like.pp ~loc
      ~formatting:!Options.Record.pattern
      ~left:lbrace ~right:rbrace
      (fields @ extra_fields)

  and pp_array ~loc ps pats =
    let pats = List.map (pp ps) pats in
    (* TODO: add an option *)
    List_like.pp ~loc ~formatting:Wrap
      ~left:PPrint.(lbracket ^^ pipe) ~right:PPrint.(pipe ^^ rbracket) pats

  and pp_or ps p1 p2 =
    let p1 =
      let ps = Printing_stack.top_is_op ~on_left:true "|" ps in
      pp ps p1
    in
    let p2 = pp ps p2 in
    let pipe = token_between p1 p2 "| " in
    let or_ = p1 ^/^ pipe ^^ p2 in
    Printing_stack.parenthesize ps or_

  and pp_constraint p ct =
    let p = pp [] p in
    let ct = Core_type.pp [] ct in
    let colon = token_between p ct ":" in
    parens (p ^/^ colon ^/^ ct)

  and pp_type typ =
    sharp ++ Longident.pp typ

  and pp_lazy ~loc ps p =
    let lazy_ = string ~loc "lazy" in
    Printing_stack.parenthesize ps (lazy_ ^/^ pp ps p)

  and pp_unpack mod_name ct =
    let mod_name = module_name ~loc:mod_name.loc mod_name.txt in
    let with_constraint =
      match ct with
      | None -> mod_name
      | Some pkg ->
        let constr = Package_type.pp pkg in
        let colon = token_between mod_name constr ":" in
        mod_name ^/^ colon ^/^ constr
    in
    enclose ~before:PPrint.(!^"(module") ~after:PPrint.(!^")")
      with_constraint

  and pp_exception ~loc ps p =
    string ~loc "exception" ^/^ pp ps p

  and pp_open lid p =
    let p = pp [] p in
    let lid = Longident.pp lid in
    concat lid (parens (break_before ~spaces:0 p)) ~sep:PPrint.dot

  and pp_desc ~loc ps = function
    | Ppat_any -> underscore ~loc
    | Ppat_var v -> str v
    | Ppat_alias (pat, alias) -> pp_alias ps pat alias
    | Ppat_constant c -> Constant.pp ~loc c
    | Ppat_interval (c1, c2) -> pp_interval c1 c2
    | Ppat_tuple pats -> pp_tuple ps pats
    | Ppat_construct (name, arg) -> pp_construct ps name arg
    | Ppat_list_lit pats -> pp_list_literal ~loc pats
    | Ppat_cons (hd, tl) -> pp_cons ps hd tl
    | Ppat_variant (tag, arg) -> pp_variant ps tag arg
    | Ppat_record (pats, closed) -> pp_record ~loc ps pats closed
    | Ppat_array pats -> pp_array ~loc ps pats
    | Ppat_or (p1, p2) -> pp_or ps p1 p2
    | Ppat_constraint (p, ct) -> pp_constraint p ct
    | Ppat_type pt -> pp_type pt
    | Ppat_lazy p -> pp_lazy ~loc ps p
    | Ppat_unpack (name, typ) -> pp_unpack name typ
    | Ppat_exception p -> pp_exception ~loc ps p
    | Ppat_extension ext -> Extension.pp Item ext
    | Ppat_open (lid, p) -> pp_open lid p
end

and Application : sig
  val pp : Printing_stack.t -> expression -> (arg_label * expression) list ->
    document
end = struct
  let argument ps (lbl, exp) =
    let suffix ~prefix lbl =
      let pre = prefix ++ str lbl in
      match exp.pexp_desc with
      | Pexp_ident Lident id when lbl.txt = id.txt -> pre
      | _ -> concat pre (Expression.pp ps exp) ~sep:PPrint.colon
    in
    match lbl with
    | Nolabel -> Expression.pp ps exp
    | Labelled lbl -> suffix ~prefix:tilde lbl
    | Optional lbl -> suffix ~prefix:qmark lbl

  let simple_apply ps exp arg args =
    let exp = Expression.pp ps exp in
    let args = separate_map (break 1) ~f:(argument ps) arg args in
    let doc = prefix ~indent:2 ~spaces:1 exp args in
    Printing_stack.parenthesize ps doc

  let prefix_op ps (exp, op) arg args =
    match fst arg with
    | Nolabel ->
      let ps = Printing_stack.Prefix_op :: List.tl ps in
      let op = str op in
      let args = separate_map (break 1) ~f:(argument ps) arg args in
      let doc = nest 2 (op ^^ args) in
      Printing_stack.parenthesize ps doc
    | _ ->
      simple_apply ps exp arg args

  let infix_op ps (exp, op) arg args =
    match arg, args with
    | (Nolabel, fst), [ (Nolabel, snd) ] ->
      let ps = Printing_stack.top_is_op ~on_left:true op.txt ps in
      let fst = Expression.pp ps fst in
      let ps = Printing_stack.top_is_op ~on_left:false op.txt ps in
      let snd = Expression.pp ps snd in
      let doc = infix ~indent:2 ~spaces:1 (str op) fst snd in
      Printing_stack.parenthesize ps doc
    | _ ->
      simple_apply ps exp arg args

  let classify_fun exp =
    match exp.pexp_desc with
    | Pexp_ident Lident s when s.txt <> "" -> Ident_class.classify s
    | _ -> Normal

  let pp ps exp = function
    | [] ->
      (* An application node without arguments? That can't happen. *)
      assert false
    | arg :: args ->
      match classify_fun exp with
      | Normal -> simple_apply ps exp arg args
      | Prefix_op op -> prefix_op ps (exp, op) arg args
      | Infix_op op -> infix_op ps (exp, op) arg args

end

and Expression : sig
  val pp : Printing_stack.t -> expression -> document
end = struct
  let rec pp ps { pexp_desc; pexp_attributes; pexp_loc; _ } =
    let desc =
      let ps = Printing_stack.Expression pexp_desc :: ps in
      group (pp_desc ~loc:pexp_loc ps pexp_desc)
    in
    Attribute.attach_to_item desc pexp_attributes

  and pp_desc ~loc ps = function
    | Pexp_ident id -> pp_ident id
    | Pexp_constant c -> Constant.pp ~loc c
    | Pexp_let (rf, vbs, body) -> pp_let ps rf vbs body
    | Pexp_function cases -> pp_function ps cases
    | Pexp_fun (params, exp) ->
      pp_fun ~loc ps params exp
    | Pexp_apply (expr, args) -> Application.pp ps expr args
    | Pexp_match (arg, cases) -> pp_match ps arg cases
    | Pexp_try (arg, cases) -> pp_try ps arg cases
    | Pexp_tuple exps -> pp_tuple ps exps
    | Pexp_list_lit exps -> pp_list_literal ~loc ps exps
    | Pexp_cons (hd, tl) -> pp_cons ps hd tl
    | Pexp_construct (lid, arg) -> pp_construct ~loc ps lid arg
    | Pexp_variant (tag, arg) -> pp_variant ~loc ps tag arg
    | Pexp_record (fields, exp) -> pp_record ~loc ps fields exp
    | Pexp_field (exp, fld) -> pp_field ps exp fld
    | Pexp_setfield (exp, fld, val_) -> pp_setfield ps exp fld val_
    | Pexp_array elts -> pp_array ~loc ps elts
    | Pexp_ifthenelse (cond, then_, else_) ->
      pp_if_then_else ~loc ps cond then_ else_
    | Pexp_sequence (e1, e2) -> pp_sequence ps e1 e2
    | Pexp_while (cond, body) -> pp_while ~loc cond body
    | Pexp_for (it, start, stop, dir, body) -> pp_for ~loc it start stop dir body
    | Pexp_constraint (e, ct) -> pp_constraint e ct
    | Pexp_coerce (e, ct_start, ct) -> pp_coerce e ct_start ct
    | Pexp_send (e, meth) -> pp_send ps e meth
    | Pexp_new lid -> pp_new lid
    | Pexp_setinstvar (lbl, exp) -> pp_setinstvar ps lbl exp
    | Pexp_override fields -> pp_override ~loc fields
    | Pexp_letmodule (name, mb, body) -> pp_letmodule ~loc ps name mb body
    | Pexp_letexception (exn, exp) -> pp_letexception ~loc ps exn exp
    | Pexp_assert exp -> pp_assert ~loc ps exp
    | Pexp_lazy exp -> pp_lazy ~loc ps exp
    | Pexp_object cl -> pp_object cl
    | Pexp_pack (me, pkg) -> pp_pack me pkg
    | Pexp_open (lid, exp) -> pp_open lid exp
    | Pexp_letopen (od, exp) -> pp_letopen ~loc ps od exp
    | Pexp_letop letop -> pp_letop letop
    | Pexp_extension ext -> Extension.pp Item ext
    | Pexp_unreachable -> string ~loc "."
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
        let keyword = if i = 0 then "let" ^ rec_flag rf else "and" in
        let keyword =
          (* FIXME: pvb_loc should be pvb_start_loc *)
          let loc =
            { vb.pvb_loc with loc_end = vb.pvb_pat.ppat_loc.loc_start }
          in
          string ~loc keyword
        in
        Binding.pp ~keyword binding
      ) vbs
    in
    let vbs = separate hardline (List.hd vbs) (List.tl vbs) in
    let body =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps body
    in
    let in_ = token_between vbs body "in" in
    Printing_stack.parenthesize ps (group (vbs ^/^ in_) ^^ hardline ++ body)

  and rec_flag = function
    | Recursive -> " rec"
    | Nonrecursive -> ""

  and case ps { pc_lhs; pc_guard; pc_rhs } =
    let lhs = Pattern.pp [] pc_lhs in
    let rhs = pp ps pc_rhs in
    let lhs =
      match pc_guard with
      | None -> lhs
      | Some guard ->
        let guard = pp ps guard in
        let when_ = token_between lhs guard "when" in
        lhs ^/^ group (when_ ^/^ guard)
    in
    let arrow = token_between lhs rhs "->" in
    let lhs = group (lhs ^^ nest 2 (break_before arrow)) in
    match !Options.Cases.body_on_separate_line with
    | Always -> lhs ^^ nest !Options.Cases.body_indent (hardline ++ rhs)
    | When_needed -> prefix ~indent:!Options.Cases.body_indent ~spaces:1 lhs rhs

  and cases ps c cs =
    let cases =
      separate_map PPrint.(break 1 ^^ pipe ^^ space) ~f:(case ps) c cs
    in
    let prefix =
      let open PPrint in
      ifflat empty (hardline ^^ pipe) ^^ space
    in
    prefix ++ cases

  and pp_function ps = function
    | [] -> assert false (* always at least one case *)
    | c :: cs ->
      let doc = !^"function" ++ cases ps c cs in
      Printing_stack.parenthesize ps doc

  and fun_ ~loc ~args ~body =
    let fun_ =
      let loc = { loc with Location.loc_end = args.loc.loc_start } in
      string ~loc "fun"
    in
    let arrow = token_between args body "->" in
    prefix ~indent:2 ~spaces:1
      (group ((prefix ~indent:2 ~spaces:1 fun_ args) ^/^ arrow))
      body

  and pp_fun ~loc ps params exp =
    match params with
    | [] -> assert false
    | param :: params ->
      let body = pp ps exp in
      let args = left_assoc_map ~sep:PPrint.empty ~f:Fun_param.pp param params in
      let doc = fun_ ~loc ~args ~body in
      Printing_stack.parenthesize ps doc

  and pp_match ps arg = function
    | [] -> assert false (* always at least one case *)
    | c :: cs ->
      let arg = pp [] arg in
      let cases = cases ps c cs in
      let with_ = token_between arg cases "with" in
      let doc =
        group (
          (* FIXME: location for match. *)
          !^"match" ++
          nest 2 (break_before arg) ^/^
          with_
        ) ^^ cases
      in
      Printing_stack.parenthesize ps 
        ~situations:!Options.Match.parenthesing_situations
        ~style:!Options.Match.parens_style
        doc

  and pp_try ps arg = function
    | [] -> assert false
    | c :: cs ->
      let arg = pp [] arg in
      let cases = cases ps c cs in
      let with_ = token_between arg cases "with" in
      let doc =
        group (
          (* FIXME: location for try *)
          !^"try" ++
          nest 2 (break_before arg)
        ) ^/^
        with_ ^^
        cases
      in
      Printing_stack.parenthesize ps doc

  and pp_tuple ps = function
    | [] -> assert false
    | exp :: exps ->
      let doc =
        group (separate_map PPrint.(comma ^^ break 1) ~f:(pp ps) exp exps)
      in
      Printing_stack.parenthesize ps doc

  and pp_construct ~loc ps lid arg_opt =
    let name = Longident.pp lid in
    let arg  = optional ~loc (pp ps) arg_opt in
    let doc  = prefix ~indent:2 ~spaces:1 name arg in
    Printing_stack.parenthesize ps doc

  and pp_cons ps hd tl =
    let ps = Printing_stack.top_is_op ~on_left:true "::" ps in
    let hd = Expression.pp ps hd in
    let ps = Printing_stack.top_is_op ~on_left:false "::" ps in
    let tl = Expression.pp ps tl in
    let cons = token_between hd tl "::" in
    let doc = infix ~indent:2 ~spaces:1 cons hd tl in
    Printing_stack.parenthesize ps doc

  and pp_list_literal ~loc ps elts =
    let elts = List.map (pp ps) elts in
    List_like.pp ~loc
      ~formatting:Wrap (* TODO: add an option *)
      ~left:lbracket ~right:rbracket
      elts

  and pp_variant ~loc ps tag arg_opt =
    let tag = Polymorphic_variant_tag.pp tag in
    let arg  = optional ~loc (pp ps) arg_opt in
    let doc  = prefix ~indent:2 ~spaces:1 tag arg in
    Printing_stack.parenthesize ps doc

  and record_field (lid, exp) =
    let fld = Longident.pp lid in
    group (
      match exp.pexp_desc with
      | Pexp_ident Lident id when (Long_ident.last lid).txt = id.txt -> fld
      | _ ->
        let exp = pp [ Printing_stack.Record_field ] exp in
        let equals = token_between fld exp "=" in
        group (fld ^/^ equals) ^^ nest 2 (break_before exp)
    )

  and pp_record ~loc ps fields updated_record =
    let fields = List.map record_field fields in
    match updated_record with
    | None ->
      List_like.pp ~loc
        ~formatting:!Options.Record.expression
        ~left:lbrace
        ~right:rbrace
        fields
    | Some e ->
      let update = pp ps e in
      let fields =
        List_like.pp_fields ~formatting:!Options.Record.expression
          (List.hd fields) (List.tl fields)
      in
      let with_ = token_between update fields "with" in
      enclose ~before:lbrace ~after:PPrint.(break 1 ^^ rbrace)
        (group (group (break_before update) ^/^ with_) ^/^ fields)

  and pp_field ps re fld =
    let record = pp ps re in
    let field = Longident.pp fld in
    let dot = token_between record field "." in
    flow (break 0) record [ dot; field ]

  and pp_setfield ps re fld val_ =
    let field = pp_field ps re fld in
    let value = pp (List.tl ps) val_ in
    let larrow = token_between field value "<-" in
    prefix ~indent:2 ~spaces:1
      (group (field ^/^ larrow))
      value

  and pp_array ~loc ps elts =
    let elts = List.map (pp ps) elts in
    (* TODO: add an option *)
    List_like.pp ~loc ~formatting:Wrap
      ~left:PPrint.(lbracket ^^ pipe)
      ~right:PPrint.(pipe ^^ rbracket) elts

  (* FIXME: change ast to present n-ary [if]s *)
  and pp_if_then_else ~loc ps cond then_ else_opt =
    let if_ =
      let cond = pp [] cond in
      let then_branch = pp ps then_ in
      let then_ = token_between cond then_branch "then" in
      group (
        (* FIXME! ++ is not ok *)
        !^"if" ++
        nest 2 (break_before cond) ^/^
        then_
      ) ^^ 
      nest 2 (break_before then_branch)
    in
    let else_ =
      let loc = { loc with Location.loc_start = if_.loc.loc_end } in
      optional ~loc (fun e ->
        let else_branch = pp ps e in
        let else_ = token_between if_ else_branch "else" in
        break_before else_ ^^
        nest 2 (break_before else_branch)
      ) else_opt
    in
    group (if_ ^^ else_)

  and pp_sequence ps e1 e2 =
    let e1 = pp ps e1 in
    let e2 =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps e2
    in
    let semi = token_between e1 e2 ";" in
    let doc = e1 ^^ semi ^/^ e2 in
    Printing_stack.parenthesize ps doc

  and pp_while ~(loc:Location.t) cond body =
    let cond = pp [] cond in
    let body = pp [] body in
    let do_ = token_between cond body "do" in
    let loc_start = { loc with loc_end = cond.loc.loc_start } in
    let loc_end = { loc with loc_start = body.loc.loc_end } in
    group (
      group (
        string ~loc:loc_start "while" ^^
        nest 2 (break_before cond) ^/^
        do_
      ) ^^
      nest 2 (break_before body) ^/^
      string ~loc:loc_end "done"
    ) 

  and pp_for ~(loc:Location.t) it start stop dir body =
    let it = Pattern.pp [ Printing_stack.Value_binding ] it in
    let start = pp [] start in
    let equals = token_between it start "=" in
    let stop = pp [] stop in
    let dir =
      token_between start stop
        (match dir with
         | Upto -> "to"
         | Downto -> "downto")
    in
    let body = pp [] body in
    let do_ = token_between stop body "do" in
    let loc_start = { loc with loc_end = it.loc.loc_start } in
    let loc_end = { loc with loc_start = body.loc.loc_end } in
    group (
      group (
        string ~loc:loc_start "for" ^^
        nest 2 (
          break_before (group (it ^/^ equals ^/^ start)) ^/^
          dir ^/^
          stop
        ) ^/^
        do_
      ) ^^
      nest 2 (break_before body) ^/^
      string ~loc:loc_end "done"
    )

  and pp_constraint exp ct =
    let exp = pp [] exp in
    let ct = Core_type.pp [] ct in
    let colon = token_between exp ct ":" in
    group (parens (exp ^/^ colon ^/^ ct))

  and pp_coerce exp ct_start ct =
    let exp = pp [] exp in
    let ct = Core_type.pp [] ct in
    let ct_start =
      let loc = { exp.loc with loc_start = exp.loc.loc_end } in
      optional ~loc (fun ct ->
        let ct = Core_type.pp [] ct in
        let colon = token_between exp ct ":" in
        break_before colon ^/^ ct
      ) ct_start
    in
    let coerce = token_between ct_start ct ":>" in
    group (parens (group (exp ^^ ct_start) ^/^ coerce ^/^  ct))

  and pp_send ps exp met =
    let exp =
      let ps = Printing_stack.top_is_op ~on_left:true "#" ps in
      pp ps exp
    in
    let met = str met in
    let sharp = token_between exp met "#" in
    let doc = flow (break 0) exp [ sharp; met ] in
    Printing_stack.parenthesize ps doc

  and pp_new lid =
    Longident.pp lid

  and pp_setinstvar ps lbl exp =
    let lbl = str lbl in
    let exp = pp (List.tl ps) exp in
    let larrow = token_between lbl exp "<-" in
    let doc = lbl ^/^ larrow ^/^ exp in
    Printing_stack.parenthesize ps doc

  and obj_field_override (lbl, exp) =
    let fld = str lbl in
    let exp = pp [ Printing_stack.Record_field ] exp in
    let equals = token_between fld exp "=" in
    fld ^/^ equals ^/^ exp

  and pp_override ~loc fields =
    List_like.pp ~loc
      ~formatting:!Options.Record.expression
      ~left:PPrint.(lbrace ^^ langle)
      ~right:PPrint.(rangle ^^ rbrace)
      (List.map obj_field_override fields)

  and pp_letmodule ~loc ps name (params, typ, mexp) expr =
    let binding = Module_binding.pp_raw name params typ mexp [] in
    let bind =
      let keyword = 
        let loc = { loc with loc_end = name.loc.loc_start } in
        string ~loc "let module"
      in
      Binding.Module.pp ~keyword binding
    in
    let expr =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps expr
    in
    let in_ = token_between bind expr "in" in
    let doc = bind ^/^ in_ ^/^ expr in
    Printing_stack.parenthesize ps doc

  and pp_letexception ~(loc:Location.t) ps exn exp =
    let exn = Constructor_decl.pp_extension exn in
    let exp =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps exp
    in
    let keyword = 
      let loc = { loc with loc_end = exn.loc.loc_start } in
      string ~loc "let exception"
    in
    let in_ = token_between exn exp "in" in
    let doc =
      group (prefix ~indent:2 ~spaces:1 keyword
               (group (exn ^/^ in_)))
      ^^ exp
    in
    Printing_stack.parenthesize ps doc

  and pp_assert ~(loc:Location.t) ps exp =
    let exp = pp ps exp in
    let assert_ = 
      let loc = { loc with loc_end = exp.loc.loc_start } in
      string ~loc "assert"
    in
    let doc = prefix ~indent:2 ~spaces:1 assert_ exp in
    Printing_stack.parenthesize ps doc

  and pp_lazy ~(loc:Location.t) ps exp =
    let exp = pp ps exp in
    let lazy_ = 
      let loc = { loc with loc_end = exp.loc.loc_start } in
      string ~loc "lazy"
    in
    let doc = prefix ~indent:2 ~spaces:1 lazy_ exp in
    Printing_stack.parenthesize ps doc

  and pp_object cl =
    let cl = Class_structure.pp cl in
    group (
      enclose ~before:!^"object" ~after:PPrint.(break 1 ^^ !^"end")
        (nest 2 (break_before cl))
    )


  and pp_pack me pkg =
    let me = Module_expr.pp me in
    let with_constraint =
      match pkg with
      | None -> me
      | Some pkg ->
        let constr = Package_type.pp pkg in
        let colon = token_between me constr ":" in
        me ^/^ colon ^/^ constr
    in
    enclose ~before:PPrint.(!^"(module") ~after:PPrint.(!^")")
      with_constraint

  and pp_open lid exp =
    let lid = Longident.pp lid in
    let exp = pp [] exp in
    let dot = token_between lid exp "." in
    let exp =
      enclose exp
        ~before:PPrint.(lparen ^^ break 0)
        ~after:PPrint.(break 0 ^^ rparen)
    in
    lid ^^ dot ^^ exp

  and pp_letopen ~(loc:Location.t) ps od exp =
    let od = Open_declaration.pp Attached_to_item od in
    let exp =
      let ps = if Printing_stack.will_parenthesize ps then [] else List.tl ps in
      pp ps exp
    in
    let in_ = token_between od exp "in" in
    let let_ = 
      let loc = { loc with loc_end = od.loc.loc_start } in
      string ~loc "let"
    in
    let doc = group (let_ ^^ od ^^ in_) ^/^ exp in
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
