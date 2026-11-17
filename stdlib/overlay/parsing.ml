(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* The parsing engine *)

open Lexing

(* Internal interface to the parsing engine *)

type parser_env =
  { mutable s_stack : int array;        (* States *)
    mutable v_stack : Obj.t array;      (* Semantic attributes *)
    mutable symb_start_stack : position array; (* Start positions *)
    mutable symb_end_stack : position array;   (* End positions *)
    mutable stacksize : int;            (* Size of the stacks *)
    mutable stackbase : int;            (* Base sp for current parse *)
    mutable curr_char : int;            (* Last token read *)
    mutable lval : Obj.t;               (* Its semantic attribute *)
    mutable symb_start : position;      (* Start pos. of the current symbol*)
    mutable symb_end : position;        (* End pos. of the current symbol *)
    mutable asp : int;                  (* The stack pointer for attributes *)
    mutable rule_len : int;             (* Number of rhs items in the rule *)
    mutable rule_number : int;          (* Rule number to reduce by *)
    mutable sp : int;                   (* Saved sp for parse_engine *)
    mutable state : int;                (* Saved state for parse_engine *)
    mutable errflag : int }             (* Saved error flag for parse_engine *)
[@@warning "-unused-field"]

type parse_tables =
  { actions : (parser_env -> Obj.t) array;
    transl_const : int array;
    transl_block : int array;
    lhs : string;
    len : string;
    defred : string;
    dgoto : string;
    sindex : string;
    rindex : string;
    gindex : string;
    tablesize : int;
    table : string;
    check : string;
    error_function : string -> unit;
    names_const : string;
    names_block : string }

exception YYexit of Obj.t
exception Parse_error

type parser_input =
    Start
  | Token_read
  | Stacks_grown_1
  | Stacks_grown_2
  | Semantic_action_computed
  | Error_detected

type parser_output =
    Read_token
  | Raise_parse_error
  | Grow_stacks_1
  | Grow_stacks_2
  | Compute_semantic_action
  | Call_error_function

(* to avoid warnings *)
let _ = [Read_token; Raise_parse_error; Grow_stacks_1; Grow_stacks_2;
         Compute_semantic_action; Call_error_function]

(* ARC-native interpreter for the packed LR tables emitted by ocamlyacc. *)
let trace_enabled = ref false
let set_trace enabled =
  let previous = !trace_enabled in
  trace_enabled := enabled;
  previous

let trace format =
  if !trace_enabled then Printf.eprintf format else Printf.ifprintf stderr format

let short table index =
  let value = String.get_uint16_le table (2 * index) in
  if value land 0x8000 = 0 then value else value - 0x10000

let token_name names number =
  let rec find offset remaining =
    if offset >= String.length names || names.[offset] = '\000' then "<unknown token>"
    else
      let stop = String.index_from names offset '\000' in
      if remaining = 0 then String.sub names offset (stop - offset)
      else find (stop + 1) (remaining - 1)
  in
  find 0 number

let parse_engine tables env command argument =
  let matches base token =
    let index = base + token in
    base <> 0 && index >= 0 && index <= tables.tablesize
    && short tables.check index = token
  in
  let rec loop () =
    let rule = short tables.defred env.state in
    if rule <> 0 then reduce rule
    else if env.curr_char < 0 then Read_token
    else test_shift ()
  and test_shift () =
    let base = short tables.sindex env.state in
    if matches base env.curr_char then begin
      let next = short tables.table (base + env.curr_char) in
      env.curr_char <- -1;
      if env.errflag > 0 then env.errflag <- env.errflag - 1;
      shift next
    end else begin
      let base = short tables.rindex env.state in
      if matches base env.curr_char then
        reduce (short tables.table (base + env.curr_char))
      else if env.errflag > 0 then recover ()
      else Call_error_function
    end
  and shift state =
    trace "State %d: shift to state %d\n%!" env.state state;
    env.state <- state;
    env.sp <- env.sp + 1;
    if env.sp >= env.stacksize then Grow_stacks_1 else push ()
  and push () =
    env.s_stack.(env.sp) <- env.state;
    env.v_stack.(env.sp) <- env.lval;
    env.symb_start_stack.(env.sp) <- env.symb_start;
    env.symb_end_stack.(env.sp) <- env.symb_end;
    loop ()
  and reduce rule =
    trace "State %d: reduce by rule %d\n%!" env.state rule;
    let length = short tables.len rule in
    env.asp <- env.sp;
    env.rule_number <- rule;
    env.rule_len <- length;
    env.sp <- env.sp - length + 1;
    let lhs = short tables.lhs rule in
    let state = env.s_stack.(env.sp - 1) in
    let base = short tables.gindex lhs in
    env.state <-
      if matches base state then short tables.table (base + state)
      else short tables.dgoto lhs;
    if env.sp >= env.stacksize then Grow_stacks_2 else Compute_semantic_action
  and recover () =
    if env.errflag < 3 then begin
      env.errflag <- 3;
      let rec discard () =
        let state = env.s_stack.(env.sp) in
        let base = short tables.sindex state in
        if matches base 256 then begin
          trace "Recovering in state %d\n%!" state;
          shift (short tables.table (base + 256))
        end else begin
          trace "Discarding state %d\n%!" state;
          if env.sp <= env.stackbase then begin
            trace "No more states to discard\n%!";
            Raise_parse_error
          end else begin
            env.sp <- env.sp - 1;
            discard ()
          end
        end
      in
      discard ()
    end else if env.curr_char = 0 then Raise_parse_error
    else begin
      trace "Discarding last token read\n%!";
      env.curr_char <- -1;
      loop ()
    end
  in
  match command with
  | Start -> env.state <- 0; env.errflag <- 0; loop ()
  | Token_read ->
      if Obj.is_block argument then begin
        env.curr_char <- tables.transl_block.(Obj.tag argument);
        env.lval <- Obj.field argument 0
      end else begin
        env.curr_char <- tables.transl_const.(Obj.obj argument);
        env.lval <- Obj.repr 0
      end;
      if !trace_enabled then begin
        if Obj.is_int argument then
          trace "State %d: read token %s\n%!" env.state
            (token_name tables.names_const (Obj.obj argument))
        else begin
          let value = Obj.field argument 0 in
          trace "State %d: read token %s(" env.state
            (token_name tables.names_block (Obj.tag argument));
          if Obj.is_int value then trace "%d" (Obj.obj value)
          else if Obj.tag value = Obj.string_tag then trace "%s" (Obj.obj value)
          else if Obj.tag value = Obj.double_tag then trace "%g" (Obj.obj value)
          else trace "_";
          trace ")\n%!"
        end
      end;
      test_shift ()
  | Stacks_grown_1 -> push ()
  | Stacks_grown_2 -> Compute_semantic_action
  | Semantic_action_computed ->
      env.s_stack.(env.sp) <- env.state;
      env.v_stack.(env.sp) <- argument;
      env.symb_end_stack.(env.sp) <- env.symb_end_stack.(env.asp);
      if env.sp > env.asp then
        env.symb_start_stack.(env.sp) <- env.symb_end_stack.(env.asp);
      loop ()
  | Error_detected -> recover ()

let env =
  { s_stack = Array.make 100 0;
    v_stack = Array.make 100 (Obj.repr ());
    symb_start_stack = Array.make 100 dummy_pos;
    symb_end_stack = Array.make 100 dummy_pos;
    stacksize = 100;
    stackbase = 0;
    curr_char = 0;
    lval = Obj.repr ();
    symb_start = dummy_pos;
    symb_end = dummy_pos;
    asp = 0;
    rule_len = 0;
    rule_number = 0;
    sp = 0;
    state = 0;
    errflag = 0 }

let grow_stacks() =
  let oldsize = env.stacksize in
  let newsize = oldsize * 2 in
  let new_s = Array.make newsize 0
  and new_v = Array.make newsize (Obj.repr ())
  and new_start = Array.make newsize dummy_pos
  and new_end = Array.make newsize dummy_pos in
    Array.blit env.s_stack 0 new_s 0 oldsize;
    env.s_stack <- new_s;
    Array.blit env.v_stack 0 new_v 0 oldsize;
    env.v_stack <- new_v;
    Array.blit env.symb_start_stack 0 new_start 0 oldsize;
    env.symb_start_stack <- new_start;
    Array.blit env.symb_end_stack 0 new_end 0 oldsize;
    env.symb_end_stack <- new_end;
    env.stacksize <- newsize

let clear_parser() =
  Array.fill env.v_stack 0 env.stacksize (Obj.repr ());
  env.lval <- Obj.repr ()

let current_lookahead_fun = ref (fun (_ : Obj.t) -> false)

let yyparse tables start lexer lexbuf =
  let rec loop cmd arg =
    match parse_engine tables env cmd arg with
      Read_token ->
        let t = Obj.repr(lexer lexbuf) in
        env.symb_start <- lexbuf.lex_start_p;
        env.symb_end <- lexbuf.lex_curr_p;
        loop Token_read t
    | Raise_parse_error ->
        raise Parse_error
    | Compute_semantic_action ->
        let (action, value) =
          try
            (Semantic_action_computed, tables.actions.(env.rule_number) env)
          with Parse_error ->
            (Error_detected, Obj.repr ()) in
        loop action value
    | Grow_stacks_1 ->
        grow_stacks(); loop Stacks_grown_1 (Obj.repr ())
    | Grow_stacks_2 ->
        grow_stacks(); loop Stacks_grown_2 (Obj.repr ())
    | Call_error_function ->
        tables.error_function "syntax error";
        loop Error_detected (Obj.repr ()) in
  let init_asp = env.asp
  and init_sp = env.sp
  and init_stackbase = env.stackbase
  and init_state = env.state
  and init_curr_char = env.curr_char
  and init_lval = env.lval
  and init_errflag = env.errflag in
  env.stackbase <- env.sp + 1;
  env.curr_char <- start;
  env.symb_end <- lexbuf.lex_curr_p;
  try
    loop Start (Obj.repr ())
  with exn ->
    let curr_char = env.curr_char in
    env.asp <- init_asp;
    env.sp <- init_sp;
    env.stackbase <- init_stackbase;
    env.state <- init_state;
    env.curr_char <- init_curr_char;
    env.lval <- init_lval;
    env.errflag <- init_errflag;
    match exn with
      YYexit v ->
        Obj.magic v
    | _ ->
        current_lookahead_fun :=
          (fun tok ->
            if Obj.is_block tok
            then tables.transl_block.(Obj.tag tok) = curr_char
            else tables.transl_const.(Obj.magic tok) = curr_char);
        raise exn

let peek_val env n =
  Obj.magic env.v_stack.(env.asp - n)

let symbol_start_pos () =
  let rec loop i =
    if i <= 0 then env.symb_end_stack.(env.asp)
    else begin
      let st = env.symb_start_stack.(env.asp - i + 1) in
      let en = env.symb_end_stack.(env.asp - i + 1) in
      if st <> en then st else loop (i - 1)
    end
  in
  loop env.rule_len

let symbol_end_pos () = env.symb_end_stack.(env.asp)
let rhs_start_pos n = env.symb_start_stack.(env.asp - (env.rule_len - n))
let rhs_end_pos n = env.symb_end_stack.(env.asp - (env.rule_len - n))

let symbol_start () = (symbol_start_pos ()).pos_cnum
let symbol_end () = (symbol_end_pos ()).pos_cnum
let rhs_start n = (rhs_start_pos n).pos_cnum
let rhs_end n = (rhs_end_pos n).pos_cnum

let is_current_lookahead tok =
  (!current_lookahead_fun)(Obj.repr tok)

let parse_error (_ : string) = ()
