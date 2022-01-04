(*
 * Copyright (c) 2018, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Aast
open Typing_defs
open Utils
module Env = Tast_env
module Cls = Decl_provider.Class
module MakeType = Typing_make_type
module SN = Naming_special_names

let get_constant tc (seen, has_default) = function
  | Default _ -> (seen, true)
  | Case ((_, pos, Class_const ((_, _, CI (_, cls)), (_, const))), _) ->
    if String.( <> ) cls (Cls.name tc) then (
      Errors.add_typing_error
        Typing_error.(
          enum
          @@ Primary.Enum.Enum_switch_wrong_class
               { pos; expected = strip_ns (Cls.name tc); actual = strip_ns cls });
      (seen, has_default)
    ) else (
      match SMap.find_opt const seen with
      | None -> (SMap.add const pos seen, has_default)
      | Some old_pos ->
        Errors.add_typing_error
          Typing_error.(
            enum
            @@ Primary.Enum.Enum_switch_redundant
                 { const_name = const; first_pos = old_pos; pos });
        (seen, has_default)
    )
  | Case ((_, pos, _), _) ->
    Errors.add_typing_error
      Typing_error.(enum @@ Primary.Enum.Enum_switch_not_const pos);
    (seen, has_default)

let check_enum_exhaustiveness pos tc caselist coming_from_unresolved =
  (* If this check comes from an enum inside a Tunion, then
     don't punish for having an extra default case *)
  let (seen, has_default) =
    List.fold_left ~f:(get_constant tc) ~init:(SMap.empty, false) caselist
  in
  let unhandled =
    Cls.consts tc
    |> List.map ~f:fst
    |> List.filter ~f:(fun id -> String.( <> ) id SN.Members.mClass)
    |> List.filter ~f:(fun id -> not (SMap.mem id seen))
    |> List.rev
  in
  let all_cases_handled = List.is_empty unhandled in
  let enum_err_opt =
    let open Typing_error in
    match (all_cases_handled, has_default, coming_from_unresolved) with
    | (false, false, _) ->
      (* In what order should we list the unhandled ones?
         Some people might prefer an alphabetical order.
         Some people might prefer to see the list in order of declaration.
         It honestly doesn't matter. I'm picking this because I
         like errors to be deterministic. *)
      Some
        (Primary.Enum.Enum_switch_nonexhaustive
           {
             pos;
             missing = List.sort unhandled ~compare:String.compare;
             decl_pos = Cls.pos tc;
           })
    | (true, true, false) ->
      Some
        (Primary.Enum.Enum_switch_redundant_default
           { pos; decl_pos = Cls.pos tc })
    | _ -> None
  in
  Option.iter enum_err_opt ~f:(fun err ->
      Errors.add_typing_error @@ Typing_error.enum err)

(* Small reminder:
 * - enums are localized to `Tnewtype (name, _, _)` where name is the name of
 *   the enum. This can be checked using `Env.is_enum`
 * - enum classes are not inhabited by design. The type of elements is
 *   HH\MemberOf<name, _> were name is the name of the enum class. This
 *   is localized as Tnewtype("HH\MemberOf", [enum; interface]) where
 *   enum is localized as Tclass(name, _, _) where Env.is_enum_class name is
 *   true.
 *)
(* Wrapper to share the logic that detects if a type is an enum or an enum
 * class, or something else.
 *)
let apply_if_enum_or_enum_class
    env ~(default : 'a) ~(f : Env.env -> string -> 'a) name args =
  if Env.is_enum env name then
    f env name
  else
    match args with
    | [enum; _interface] ->
      begin
        match get_node enum with
        | Tclass ((_, cid), _, _) when Env.is_enum_class env cid -> f env cid
        | _ -> default
      end
    | _ -> default

let rec check_exhaustiveness_ env pos ty caselist enum_coming_from_unresolved =
  (* Right now we only do exhaustiveness checking for enums. *)
  (* This function has a built in hack where if Tunion has an enum
     inside then it tells the enum exhaustiveness checker to
     not punish for extra default *)
  let (env, ty) = Env.expand_type env ty in
  let check env id =
    let dep = Typing_deps.Dep.AllMembers id in
    let decl_env = Env.get_decl_env env in
    Option.iter decl_env.Decl_env.droot ~f:(fun root ->
        Typing_deps.add_idep (Env.get_deps_mode env) root dep);
    let tc = unsafe_opt @@ Env.get_enum env id in
    check_enum_exhaustiveness pos tc caselist enum_coming_from_unresolved;
    env
  in
  match get_node ty with
  | Tunion tyl ->
    let new_enum =
      enum_coming_from_unresolved
      || List.length tyl > 1
         && List.exists tyl ~f:(fun cur_ty ->
                let (_, cur_ty) = Env.expand_type env cur_ty in
                match get_node cur_ty with
                | Tnewtype (name, args, _) ->
                  apply_if_enum_or_enum_class
                    env
                    ~default:false
                    ~f:(fun _ _ -> true)
                    name
                    args
                | _ -> false)
    in
    List.fold_left tyl ~init:env ~f:(fun env ty ->
        check_exhaustiveness_ env pos ty caselist new_enum)
  | Tintersection tyl ->
    fst
    @@ Typing_utils.run_on_intersection env tyl ~f:(fun env ty ->
           ( check_exhaustiveness_
               env
               pos
               ty
               caselist
               enum_coming_from_unresolved,
             () ))
  | Tnewtype (name, args, _) ->
    apply_if_enum_or_enum_class env ~default:env ~f:check name args
  | Terr
  | Tany _
  | Tnonnull
  | Tvec_or_dict _
  | Tclass _
  | Toption _
  | Tprim _
  | Tvar _
  | Tfun _
  | Tgeneric _
  | Tdependent _
  | Ttuple _
  | Tshape _
  | Tdynamic
  | Taccess _
  | Tneg _ ->
    env
  | Tunapplied_alias _ ->
    Typing_defs.error_Tunapplied_alias_in_illegal_context ()

let check_exhaustiveness env pos ty caselist =
  let (_ : Env.env) = check_exhaustiveness_ env pos ty caselist false in
  ()

let handler =
  object
    inherit Tast_visitor.handler_base

    method! at_stmt env x =
      match snd x with
      | Switch ((scrutinee_ty, scrutinee_pos, _), casel) ->
        check_exhaustiveness env scrutinee_pos scrutinee_ty casel
      | _ -> ()
  end
