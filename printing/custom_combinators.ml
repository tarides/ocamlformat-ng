open PPrint

let infix ~indent:n ~spaces:b op l r = infix n b op l r

module List_like = struct
  let docked ~left ~right x xs =
    let fmt x = nest 2 (group (break 1 ^^ x)) in
    let fields =
      List.fold_left
        (fun acc elt -> group (acc ^^ semi) ^^ fmt elt)
        (fmt x) 
        xs
    in
    left ^^ fields ^^ group (break 1 ^^ right)

  let fit_or_vertical ~left ~right elts =
    left ^^ nest 2 (
      break 1 ^^ separate (semi ^^ break 1) elts
    ) ^/^ right

  let pp ~formatting ~left ~right = function
    | [] -> left ^^ right
    | x :: xs as elts ->
      match (formatting : Options.Wrappable.t) with
      | Wrap -> docked ~left ~right x xs
      | Fit_or_vertical -> fit_or_vertical ~left ~right elts
end
