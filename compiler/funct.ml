(***********************************************************************)
(*                                                                     *)
(*                              CamlIDL                                *)
(*                                                                     *)
(*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 1999 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the GNU Lesser General Public License LGPL v2.1 *)
(*                                                                     *)
(***********************************************************************)

(* $Id: funct.ml,v 1.30 2004-07-08 09:50:23 xleroy Exp $ *)

(* Generation of stub code for functions *)

open Printf
open Utils
open Variables
open Idltypes
open Typedef
open Cvttyp
open Cvtval

type in_out =
    In | Out | InOut

type function_decl =
  { fun_name: string;
    fun_mod: string;
    fun_res: idltype;
    fun_params: (string * in_out * idltype) list;
    fun_mlname: string option;
    fun_call: string option;
    fun_dealloc: string option;
    fun_blocking: bool }

(* Remove dependent parameters (parameters that are size_is, length_is,
   or switch_is of another parameter).
   Note: an "in" parameter that is size_is of an "out" parameter
   cannot be removed.
   Also remove ignored pointers. *)

let is_dependent_parameter name mode params =
  List.exists
    (fun (_, mode', ty) ->
      Lexpr.is_dependent name ty && (mode' <> Out || mode = Out))
    params

let remove_dependent_parameters params =
  list_filter
    (fun (name, mode, ty) ->
      not (is_dependent_parameter name mode params || is_ignored ty))
    params

(* Split parameters into in parameters and out parameters.
   In/out get copied to both. Inout (in place) are viewed as in. *)

let rec split_in_out = function
    [] -> ([], [])
  | (name, inout, ty) :: rem ->
      let (ins, outs) = split_in_out rem in
      match inout with
        In -> ((name, ty) :: ins, outs)
      | Out -> (ins, (name, ty) :: outs)
      | InOut ->
          match ty with
            Type_array({is_bytes = true}, _) | Type_bigarray(_, _) ->
              ((name, ty) :: ins, outs)
          | _ ->
              ((name, ty) :: ins, (name, ty) :: outs)

(* Determine if a typedef represents an error code *)

let rec is_errorcode = function
    Type_named(modl, name) -> (!Typedef.find name).td_errorcode
  | Type_pointer(kind, ty) -> is_errorcode ty
  | Type_const ty -> is_errorcode ty
  | _ -> false

(* Convert the C view of parameters and result into the ML view:
    - remove dependent parameters
    - turn out and in/out parameters into extra results
    - remove void and errorcode return values *)

let ml_view fundecl =
  let true_params = remove_dependent_parameters fundecl.fun_params in
  let (ins, outs) = split_in_out true_params in
  (* Add return value as an out if it's not void and not an error code *)
  let outs2 =
    if fundecl.fun_res = Type_void || is_errorcode fundecl.fun_res
    then outs
    else ("_res", fundecl.fun_res) :: outs in
  (* Remove out parameters that are error codes *)
  (ins, outs2)

(* Generate the ML declaration for a function *)

let mlname fundecl =
  match fundecl.fun_mlname with Some n -> n | None -> fundecl.fun_name

let ml_declaration oc fundecl =
  let (ins, outs) = ml_view fundecl in
  fprintf oc "external %s : " (String.uncapitalize_ascii (mlname fundecl));
  out_ml_types oc "->" ins;
  fprintf oc " -> ";
  out_ml_types oc "*" outs;
  if List.length ins <= 5
  then fprintf oc "\n\t= \"camlidl_%s_%s\"\n\n"
                  fundecl.fun_mod fundecl.fun_name
  else fprintf oc "\n\t= \"camlidl_%s_%s_bytecode\" \"camlidl_%s_%s\"\n\n"
                  fundecl.fun_mod fundecl.fun_name
                  fundecl.fun_mod fundecl.fun_name

(* Print a warm fuzzy in/out comment *)

let out_inout oc = function
    In -> fprintf oc "in"
  | Out -> fprintf oc "out"
  | InOut -> fprintf oc "in,out"

(* Generate the C declaration for a function *)

let c_declaration oc fundecl =
  fprintf oc "_CAMLIDL_EXTERN_C %a(" out_c_decl (fundecl.fun_name, fundecl.fun_res);
  begin match fundecl.fun_params with
    [] -> fprintf oc "void"
  | p1 :: pl ->
      let out_param (name, inout, ty) =
        fprintf oc "/*%a*/ %a" out_inout inout out_c_decl (name, ty) in
      out_param p1;
      List.iter (fun p -> fprintf oc ", "; out_param p) pl
  end;
  fprintf oc ");\n\n"

(* If context is needed, set it up (transient allocation, transient
   interface refs) *)

let output_context before after =
  if !need_context then begin
    fprintf before
      "  struct camlidl_ctx_struct _ctxs = { CAMLIDL_TRANSIENT, NULL };\n";
    fprintf before "  camlidl_ctx _ctx = &_ctxs;\n";
    iprintf after "camlidl_free(_ctx);\n"
  end

(* If a deallocation sequence is provided, insert it *)

let output_dealloc oc dealloc =
  match dealloc with
    None -> ()
  | Some s ->
      iprintf oc "/* begin user-supplied deallocation sequence */\n";
      output_string oc s;
      output_char oc '\n';
      iprintf oc "/* end user-supplied deallocation sequence */\n"

(* Call an error checking function if needed *)

let rec call_error_check oc name ty =
  match ty with
    Type_named(modl, ty_name) ->
      begin match !Typedef.find ty_name with
        {td_errorcheck = Some fn} -> iprintf oc "%s(%s);\n" fn name
      | _ -> ()
      end
  | Type_pointer(kind, ty_elt) ->
      call_error_check oc ("*" ^ name) ty_elt
  | Type_const ty' ->
      call_error_check oc name ty'
  | _ -> ()

(* Shared code between emit_wrapper and emit_method_wrapper *)

let emit_function oc fundecl ins outs locals emit_call =
  need_context := false;
  (* Emit function header *)
  fprintf oc "value camlidl_%s_%s(" fundecl.fun_mod fundecl.fun_name;
  begin match ins with
    [] ->
      fprintf oc "value _unit)\n"
  | (name1, ty1) :: rem ->
      fprintf oc "\n\tvalue _v_%s" name1;
      List.iter
        (fun (name, ty) -> fprintf oc ",\n\tvalue _v_%s" name)
        rem;
      fprintf oc ")\n"
  end;
  fprintf oc "{\n";
  (* Declare C local variables to hold parameters and result *)
  List.iter
    (fun (name, inout, ty) ->
      fprintf oc "  %a; /*%a*/\n"
              out_c_decl (name, scrape_const ty) out_inout inout)
    locals;
  if fundecl.fun_res <> Type_void then
    fprintf oc "  %a;\n" out_c_decl ("_res", scrape_const fundecl.fun_res);
  let pc = divert_output() in
  increase_indent();
  (* Initialize dependent parameters that are pointers so that they
     point to suitable storage *)
  List.iter
    (function (name, _,
               (Type_pointer(_, ty_arg) | Type_const(Type_pointer(_, ty_arg))))
              when is_dependent_parameter name In fundecl.fun_params ->
                  let c = new_c_variable ty_arg in
                  iprintf pc "%s = &%s;\n" name c
            | _ -> ())
    fundecl.fun_params;
  (* Convert ins from ML to C *)
  let pref = Prefix.enter_function fundecl.fun_params in
  List.iter
    (fun (name, ty) -> ml_to_c pc true pref ty (sprintf "_v_%s" name) name)
    ins;
  (* Initialize outs that are pointers or arrays so that they point
     to suitable storage *)
  List.iter
    (function (name, Out, ty) -> allocate_output_space pc pref name ty
            | _ -> ())
    fundecl.fun_params;
  (* Generate the call to the C function *)
  emit_call pc fundecl;
  (* Call error checking functions on result and out parameters
     that need it *)
  call_error_check pc "_res" fundecl.fun_res;
  List.iter
    (function (name, (Out|InOut), ty) -> call_error_check pc name ty
            | _ -> ())
    fundecl.fun_params;
  (* Convert outs from C to ML *)
  begin match outs with
    [] ->
      output_variable_declarations oc;
      output_context oc pc;
      output_dealloc pc fundecl.fun_dealloc;
      iprintf pc "return Val_unit;\n"
  | [name, ty] ->
      c_to_ml pc pref ty name "_vres";
      output_variable_declarations oc;
      fprintf oc "  value _vres;\n\n";
      output_context oc pc;
      output_dealloc pc fundecl.fun_dealloc;
      iprintf pc "return _vres;\n";
  | _ ->
      let num_outs = List.length outs in
      iprintf pc "Begin_roots_block(_vres, %d)\n" num_outs;
      increase_indent();
      let pos = ref 0 in
      List.iter
        (fun (name, ty) ->
          c_to_ml pc pref ty name (sprintf "_vres[%d]" !pos);
          incr pos)
        outs;
      iprintf pc "_vresult = camlidl_alloc_small(%d, 0);\n" num_outs;
      copy_values_to_block pc "_vres" "_vresult" num_outs;
      decrease_indent();
      iprintf pc "End_roots()\n";
      output_context oc pc;
      output_dealloc pc fundecl.fun_dealloc;
      iprintf pc "return _vresult;\n";
      output_variable_declarations oc;
      fprintf oc "  value _vresult;\n";
      fprintf oc "  value _vres[%d] = { " num_outs;
      for i = 1 to num_outs do fprintf oc "0, " done;
      fprintf oc "};\n\n"
  end;
  end_diversion oc;
  decrease_indent();
  fprintf oc "}\n\n";
  (* If more than 5 arguments, create an extra wrapper for the bytecode
     interface *)
  if List.length ins > 5 then begin
    fprintf oc "value camlidl_%s_%s_bytecode(value * argv, int argn)\n"
               fundecl.fun_mod fundecl.fun_name;
    fprintf oc "{\n";
    fprintf oc "  return camlidl_%s_%s(argv[0]" fundecl.fun_mod fundecl.fun_name;
    for i = 1 to List.length ins - 1 do
      fprintf oc ", argv[%d]" i
    done;
    fprintf oc ");\n";
    fprintf oc "}\n\n"
  end

(* Emit wrapper function for C function *)

let emit_standard_call oc fundecl =
  if fundecl.fun_blocking then iprintf oc "enter_blocking_section();\n";
  begin match fundecl.fun_call with
    Some s ->
      iprintf oc "/* begin user-supplied calling sequence */\n";
      output_string oc s;
      output_char oc '\n';
      iprintf oc "/* end user-supplied calling sequence */\n"
  | None ->
    if fundecl.fun_res = Type_void
    then iprintf oc ""
    else iprintf oc "_res = ";
    fprintf oc "%s(" fundecl.fun_name;
    begin match fundecl.fun_params with
      [] -> ()
    | (name1, _,_) :: rem ->
        fprintf oc "%s" name1;
        List.iter (fun (name, _, _) -> fprintf oc ", %s" name) rem
    end;
    fprintf oc ");\n"
  end;
  if fundecl.fun_blocking then iprintf oc "leave_blocking_section();\n"

let emit_wrapper oc fundecl =
  current_function := fundecl.fun_name;
  let (ins, outs) = ml_view fundecl in
  emit_function oc fundecl ins outs fundecl.fun_params emit_standard_call;
  current_function := ""

(* Emit wrapper function for COM method *)

let emit_method_call intfname methname oc fundecl =
  (* Extract "this" parameter *)
  iprintf oc "this = camlidl_unpack_interface(_v_this, NULL);\n";
  (* Reset the error mechanism *)
  iprintf oc "SetErrorInfo(0L, NULL);\n";
  (* Emit the call *)
  if fundecl.fun_blocking then iprintf oc "enter_blocking_section();\n";
  begin match fundecl.fun_call with
    Some s ->
      iprintf oc "/* begin user-supplied calling sequence */\n";
      output_string oc s;
      iprintf oc "/* end user-supplied calling sequence */\n"
  | None ->
    if fundecl.fun_res = Type_void
    then iprintf oc ""
    else iprintf oc "_res = ";
    fprintf oc "this->lpVtbl->%s(this" methname;
    List.iter (fun (name, _, _) -> fprintf oc ", %s" name) fundecl.fun_params;
    fprintf oc ");\n"
  end;
  if fundecl.fun_blocking then iprintf oc "leave_blocking_section();\n"

let emit_method_wrapper oc intf_name meth =
  current_function := sprintf "%s %s" intf_name meth.fun_name;
  let fundecl =
    {meth with fun_name = sprintf "%s_%s" intf_name meth.fun_name} in
  let (ins1, outs) = ml_view fundecl in
  (* Add an ML parameter and a C local for "this" *)
  let intf_type = Type_pointer(Ignore, Type_interface("", intf_name)) in
  let ins = ("this", intf_type) :: ins1 in
  let locals = ("this", In, intf_type) :: fundecl.fun_params in
  emit_function oc fundecl ins outs locals
                   (emit_method_call intf_name meth.fun_name);
  current_function := ""
