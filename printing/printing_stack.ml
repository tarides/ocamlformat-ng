open Source_parsing
open Source_tree

type core_type_elt =
  | Arrow
  | Tuple

type elt =
  | Attribute
  | Core_type of core_type_desc
  | Pattern of pattern_desc
  | Expression of expression_desc
  | Function_parameter
  | Value_binding
  | Cons_constr of { on_left: bool }
  | Pipe of { on_left: bool }
  | Prefix_op
  | Infix_op of { on_left: bool; level: int (* gloups *); }
  | Row_field
  | Record_field
  | Unpack

(* Cf.  http://caml.inria.fr/pub/docs/manual-ocaml/expr.html#ss:precedence-and-associativity *)
let infix_op ~on_left = function
  | "" -> assert false
  | "::" -> Cons_constr { on_left }
  | "|" -> Pipe { on_left }
  | "<-" | ":=" -> Infix_op { on_left; level = 1}
  | "or" | "||" -> Infix_op { on_left; level = 2}
  | "&"  | "&&" -> Infix_op { on_left; level = 3}
  | "!=" -> Infix_op { on_left; level = 4}
  | "mod" | "land" | "lor" | "lxor" -> Infix_op { on_left; level = 7}
  | "lsl" | "lsr" | "asr" -> Infix_op { on_left; level = 8}
  | s ->
    match String.get s 0 with
    | '=' | '<' | '>' | '|' | '&' | '$' -> Infix_op { on_left; level = 4}
    | '@' | '^' -> Infix_op { on_left; level = 5}
    | '+' | '-' -> Infix_op { on_left; level = 6}
    | '/' | '%' ->  Infix_op { on_left; level = 7}
    | '*' -> begin
        match String.get s 1 with
        | '*' -> Infix_op { on_left; level = 8}
        | _ | exception _ -> Infix_op { on_left; level = 7}
      end
    | '#' -> Infix_op { on_left; level = 9}
    | _ -> assert false

let top_is_op ~on_left op = function
  | [] -> [ infix_op ~on_left op ]
  | _ :: xs -> infix_op ~on_left op :: xs

type t = elt list

(* Refer to:
   - http://caml.inria.fr/pub/docs/manual-ocaml/types.html
   - http://caml.inria.fr/pub/docs/manual-ocaml/patterns.html
   - http://caml.inria.fr/pub/docs/manual-ocaml/expr.html#ss:precedence-and-associativity
   *)

let needs_parens elt parent =
  match elt with

  (* Type expressions *)

  (* N.B. arrows are right assoc, but since we've changed the parser and AST to
     make Ptyp_arrow n-ary, we don't need to care about that.
     If we have an arrow under another one, it means the user put parentheses,
     and the code here preserves them.  *)
  | Core_type Ptyp_arrow _
  | Core_type Ptyp_tuple _ -> begin
      match parent with
      | Core_type ( Ptyp_constr _
                  | Ptyp_class _
                  | Ptyp_arrow _
                  | Ptyp_tuple _) -> true
      | _ -> false
    end
  | Core_type Ptyp_alias _ -> begin
      match parent with
      | Core_type ( Ptyp_constr _
                  | Ptyp_class _
                  | Ptyp_arrow _
                  | Ptyp_tuple _) -> true
      | _ -> false
    end

  (* Patterns *)

  | Pattern Ppat_lazy _ -> begin
      match parent with
      | Function_parameter
      | Value_binding -> true
      | Pattern (Ppat_construct _ | Ppat_variant _) ->
        (* Not necessary: but better style. *)
        true
      | Expression (Pexp_match _ | Pexp_try _)  ->
        (* we don't require parens at the top of a match. *)
        false
      | _ -> false
    end
  | Pattern Ppat_variant (_, Some _)
  | Pattern Ppat_construct (_, Some _) -> begin
      match parent with
      | Pattern Ppat_lazy _
      | Function_parameter
      | Value_binding -> true
      | Pattern ( Ppat_construct _
                | Ppat_variant _
                | Ppat_exception _) ->
        (* Not necessary: but better style. *)
        true
      | _ -> false
    end
  | Cons_constr _ -> begin
      match parent with
      | Pattern ( Ppat_lazy _
                | Ppat_construct _
                | Ppat_variant _ )
      | Function_parameter
      | Value_binding ->
        true
      | Pattern Ppat_exception _ ->
        (* Not necessary: but better style. *)
        true
      | Prefix_op
      | Attribute
      | Expression ( Pexp_field _
                   | Pexp_setfield _
                   | Pexp_array_get _
                   | Pexp_array_set _
                   | Pexp_bigarray_get _
                   | Pexp_bigarray_set _
                   | Pexp_string_get _
                   | Pexp_string_set _
                   | Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   ) ->
        true
      | Infix_op { level; _ } -> level >= 6
      | Cons_constr { on_left } -> on_left
      | _ -> false
    end
  | Pattern Ppat_tuple _ -> begin
      match parent with
      | Pattern ( Ppat_tuple _
                | Ppat_construct _
                | Ppat_variant _
                | Ppat_lazy _
                | Ppat_exception _)
      | Cons_constr _
      | Function_parameter
      | Value_binding -> true
      | _ -> false
    end
  | Pipe _
  | Pattern Ppat_or _ -> begin
      match parent with
      | Pattern Ppat_alias _ (* Not necessary: but better style. *)
      | Pattern _
      | Attribute
      | Function_parameter
      | Value_binding ->
        true
      | Pipe { on_left } -> not on_left
      | _ -> false
    end
  | Pattern Ppat_alias _ -> begin
      match parent with
      | Pattern _
      | Function_parameter
      | Value_binding
      | Cons_constr _ -> true
      | _ -> false
    end
  | Pattern Ppat_record _ -> begin
      match parent with
      | Function_parameter -> true
      | _ -> false
    end

  (* Expressions *)

  | Prefix_op -> begin
      match parent with
      | Prefix_op -> true
      | _ -> false
    end

  | Expression Pexp_field _
  | Expression Pexp_array_get _
  | Expression Pexp_bigarray_get _
  | Expression Pexp_string_get _ -> begin
      match parent with
      | Prefix_op -> true
      | _ -> false
    end

  | Expression Pexp_send _
  | Infix_op { level = 9; _ } -> begin
      (* #... : left-assoc *)
      match parent with
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _)
      | Infix_op { level = 9; on_left = false } ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end


  | Expression Pexp_apply _
  | Expression Pexp_construct (_, Some _)
  | Expression Pexp_variant (_, Some _)
  | Expression Pexp_assert _
  | Expression Pexp_lazy _ -> begin
      match parent with
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _)
      | Infix_op { level = 9; _ }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   ) ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Attribute -> begin
      match parent with
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _)
      | Infix_op { level = 9; _ }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   ) ->
        true
      | Cons_constr { on_left = false }
      | Expression Pexp_record _
      | Function_parameter
      | Value_binding
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Infix_op { level = 8; _ } -> begin
      (* **.. lsl lsr asr : right-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _)
      | Infix_op { level = 9; _ }
      | Infix_op { level = 8; on_left = true }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   ) ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Infix_op { level = 7; _ } -> begin
      (* *.. /.. %.. mod land lor lxor: left-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (8 | 9); _ }
      | Infix_op { level = 7; on_left = false }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   ) ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Infix_op { level = 6; _ } -> begin
      (* +.. -..: left-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (7 | 8 | 9); _ }
      | Infix_op { level = 6; on_left = false }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   ) ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Infix_op { level = 5; _ } -> begin
      (* @.. ^..: right-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (6 | 7 | 8 | 9); _ }
      | Infix_op { level = 5; on_left = true }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   )
      | Cons_constr _ ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Infix_op { level = 4; _ } -> begin
      (* =.. <.. >.. |.. &.. $.. != : left-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (5 | 6 | 7 | 8 | 9); _ }
      | Infix_op { level = 4; on_left = false }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   )
      | Cons_constr _ ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end


  | Infix_op { level = 3; _ } -> begin
      (* & && : right-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (4 | 5 | 6 | 7 | 8 | 9); _ }
      | Infix_op { level = 3; on_left = true }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   )
      | Cons_constr _ ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Infix_op { level = 2; _ } -> begin
      (* or || : right-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (3 | 4 | 5 | 6 | 7 | 8 | 9); _ }
      | Infix_op { level = 2; on_left = true }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   )
      | Cons_constr _ ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Expression Pexp_tuple _ -> begin
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (2 | 3 | 4 | 5 | 6 | 7 | 8 | 9); _ }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_tuple _
                   )
      | Cons_constr _ ->
        true
      | _ -> false
    end

  | Expression Pexp_setfield _
  | Expression Pexp_array_set _
  | Expression Pexp_string_set _
  | Expression Pexp_bigarray_set _
  | Infix_op { level = 1; _ } -> begin
      (* <- := : right-assoc *)
      match parent with
      | Attribute
      | Prefix_op
      | Expression ( Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _) -> true
      | Infix_op { level = (2 | 3 | 4 | 5 | 6 | 7 | 8 | 9); _ }
      | Infix_op { level = 1; on_left = true }
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_tuple _
                   )
      | Cons_constr _ ->
        true
      | Expression Pexp_record _
      | Unpack ->
        (* Not described by the precedence table, but won't parse otherwise. *)
        true
      | _ -> false
    end

  | Expression Pexp_ifthenelse _ -> begin
      match parent with
      | Attribute
      | Prefix_op
      | Infix_op _
      | Expression ( Pexp_apply _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_record _
                   | Pexp_array _
                   | Pexp_sequence _
                   | Pexp_send _
                   )
      | Record_field
      | Unpack -> true
      | _ -> false
    end

  | Expression Pexp_object _
  | Expression Pexp_for _
  | Expression Pexp_while _ -> begin
      match parent with
      | Prefix_op
      | Infix_op _
      | Expression ( Pexp_apply _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_send _
                   )
      | Record_field -> true
      | _ -> false
    end

  | Expression Pexp_sequence _ -> begin
      match parent with
      | Attribute
      | Prefix_op
      | Infix_op _
      | Expression ( Pexp_apply _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_record _
                   | Pexp_array _
                   | Pexp_ifthenelse _
                   | Pexp_list_lit _
                   | Pexp_sequence _
                   | Pexp_send _
                   )
      | Record_field
      | Unpack -> true
      | _ -> false
    end

  | Expression Pexp_letopen _
  | Expression Pexp_let _ -> begin
      match parent with
      | Attribute
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_record _
                   | Pexp_tuple _
                   | Pexp_field _
                   | Pexp_array_get _
                   | Pexp_bigarray_get _
                   | Pexp_string_get _
                   | Pexp_setfield _
                   | Pexp_sequence _) -> true
      | Prefix_op
      | Infix_op { on_left = true; _ }
      | Cons_constr { on_left = true }
      | Record_field
      | Unpack -> true
      | _ -> false
    end
  | Expression Pexp_fun _
  | Expression Pexp_function _ -> begin
      match parent with
      | Value_binding -> false
      | _ -> true
    end
  | Expression Pexp_match _
  | Expression Pexp_try _ -> begin
      match parent with
      | Attribute
      | Expression ( Pexp_apply _
                   | Pexp_construct _
                   | Pexp_variant _
                   | Pexp_assert _
                   | Pexp_lazy _
                   | Pexp_match _
                   | Pexp_try _
                   | Pexp_function _
                   | Pexp_list_lit _
                   | Pexp_sequence _
                   | Pexp_record _
                   | Pexp_tuple _)
      | Prefix_op
      | Infix_op { on_left = true; _ }
      | Cons_constr { on_left = true }
      | Record_field
      | Unpack -> true
      | _ -> false
    end

  | _ -> false

let parenthesize ?(situations=Options.Situations.When_needed)
    ?(style=Options.Parenthesing.Parens) t doc =
  let enclosed =
    let open Document in
    match style with
    | Parens ->
      let indented = nest 1 doc in
      parens indented
    | Begin_end ->
      let indented =
        match List.hd t with
        | Expression (Pexp_match _ | Pexp_try _) -> doc
        | _ -> nest 2 doc
      in
      enclose ~before:PPrint.(!^"begin ") ~after:PPrint.(hardline ^^ !^"end")
        indented
  in
  match situations with
  | Always -> enclosed
  | When_needed ->
    match t with
    | [] -> assert false
    | elt :: parent :: _ when needs_parens elt parent -> enclosed
    | _ -> doc

let will_parenthesize t =
  match t with
  | [] -> assert false
  | [ _ ] -> false
  | elt :: parent :: _ -> needs_parens elt parent
