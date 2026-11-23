open Qbe_il

type t

type fn_info = {
  global : string;
  arity : int;
  tag : int64 option;
  group_arity : int;
  group_name : string option;
  has_closure : bool;
}

val create : ?inline_single_thread_rc:bool -> ?may_suspend:(Ident.t -> bool) -> string -> t
val may_suspend : t -> Ident.t -> bool
val module_prefix : t -> string
val sanitize : string -> string
val alloc_global_name : t -> Ident.t -> string
val fresh_name : t -> string -> string
val fresh_temp : t -> string -> Qbe_il.t
val fresh_label : t -> string -> string
val next_data_name : t -> string -> string

val add_function : t -> func -> unit
val add_data : t -> data -> unit
val finish_module : t -> initializers:func list -> module_

val bind_value : t -> Ident.t -> Qbe_il.t -> unit
val bound_value : t -> Ident.t -> Qbe_il.t
val bound_value_opt : t -> Ident.t -> Qbe_il.t option
val forget_value : t -> Ident.t -> unit
val find_ocaml_value : t -> Ident.t -> Qbe_il.t option
val with_shadowed_vars : t -> Ident.t list -> (unit -> 'a) -> 'a

val bind_slot : t -> Ident.t -> Qbe_il.t -> unit
val mutable_slot : t -> Ident.t -> Qbe_il.t
val mutable_slot_opt : t -> Ident.t -> Qbe_il.t option
val forget_slot : t -> Ident.t -> unit
val untagged_index : t -> Ident.t -> Qbe_il.t option
val with_untagged_index : t -> Ident.t -> Qbe_il.t -> (unit -> 'a) -> 'a

val function_info : t -> Ident.t -> fn_info
val function_info_opt : t -> Ident.t -> fn_info option
val declare_function : t -> Ident.t -> fn_info -> unit
val forget_function : t -> Ident.t -> unit
val record_function : t -> Ident.t -> string * bool * int -> unit
val emitted_function : t -> Ident.t -> (string * bool * int) option
val closure_wrapper : t -> Ident.t -> (unit -> string) -> string
val fresh_group_name : t -> string
val declare_group : t -> string -> (Ident.t * Anf.lfunction) list -> unit
val with_uncompiled_group : t -> string -> ((Ident.t * Anf.lfunction) list -> unit) -> unit

type tail_entry

val with_fn_state :
  ?group_entries:tail_entry Ident.Map.t ->
  ?tagged_entries:(int * (int64 * tail_entry) list) ->
  t -> self:Ident.t option -> entry_label:string ->
  in_init:bool -> (unit -> 'a) -> 'a

val self : t -> Ident.t option
val group_entry : t -> Ident.t -> tail_entry option
val in_initializer : t -> bool
val poll_tick : t -> Qbe_il.t option
val set_poll_tick : t -> Qbe_il.t option -> unit

val open_label : t -> string
val block_is_open : t -> bool
val emit : t -> inst -> unit
val emit_start_alloc : t -> Qbe_il.t -> int -> unit
val start_block : t -> string -> unit
val close_block : t -> term -> unit
val close_ret : t -> Qbe_il.t option -> unit
val finish_blocks : t -> block list
val shadow_batch_slot : t -> int -> Qbe_il.t
val tail_entry : string -> tail_entry
val tail_entry_label : tail_entry -> string
val add_entry_predecessor : t -> tail_entry -> Qbe_il.t list -> unit
val jump_to_tail_entry : t -> tail_entry -> Qbe_il.t list -> unit
val insert_entry_phis : t -> tail_entry -> (ty * string) list -> unit
val jump_to_entry : t -> Qbe_il.t list -> unit
val insert_header_phis : t -> (ty * string) list -> Qbe_il.t list -> unit

val try_handler : t -> string option
val with_try_handler : t -> string -> (unit -> 'a) -> 'a

val with_static_handler :
  t -> int -> string -> (unit -> 'a) -> 'a * (string * Qbe_il.t list) list

val jump_static_handler : t -> int -> (unit -> Qbe_il.t list) -> unit

val inline_rc : t -> bool
val compact_arc : t -> bool
val with_compact_arc : t -> (unit -> 'a) -> 'a
val emit_arc_if_heap : t -> [ `Retain | `Release ] -> Qbe_il.t -> unit
val mark_heap : t -> Qbe_il.t -> Qbe_il.t
val with_known_heap : t -> Qbe_il.t -> (unit -> 'a) -> 'a
val known_heap_slot : t -> Ident.t -> bool
val with_heap_slot : t -> Ident.t -> (unit -> 'a) -> 'a
val forget_heap_slot : t -> Ident.t -> unit
val forget_heap_slots : t -> unit

val arc_tag_array : int
val arc_tag_closure : int
val arc_tag_float_array : int
val custom_kind_int32 : int32
val custom_kind_int64 : int32
val custom_kind_nativeint : int32

val unit_const : Qbe_il.t
val tag_int : int -> int64
val ptr_offset : t -> Qbe_il.t -> int -> string -> Qbe_il.t
val untag : t -> Qbe_il.t -> Qbe_il.t
val retag : t -> Qbe_il.t -> Qbe_il.t
val cmp_of_ocaml : Lambda.integer_comparison -> Cmp.t
val pad_to : int -> Qbe_il.t list -> Qbe_il.t list
val split_at : int -> 'a list -> 'a list * 'a list

val string_data : t -> string -> string
val float_data : t -> float -> string
val custom_data : t -> int32 -> int64 -> string
val float_array_data : t -> float list -> string
val emit_const_block : t -> int -> Anf.const_item list -> string

val compile_bounds_guarded :
  t -> ?drop_on_oob:Qbe_il.t -> ?on_oob:(unit -> unit) -> ?result_type:ty ->
  Qbe_il.t -> Qbe_il.t -> (unit -> Qbe_il.t) -> Qbe_il.t

val compile_bytes_slice_bounds_guarded :
  t -> ?on_oob:(unit -> unit) -> ?result_type:ty ->
  Qbe_il.t -> Qbe_il.t -> int ->
  (unit -> Qbe_il.t) -> Qbe_il.t

val string_len_raw : t -> Qbe_il.t -> Qbe_il.t
val array_len_raw : t -> Qbe_il.t -> Qbe_il.t
val emit_block_alloc :
  t -> ?reuse:(Qbe_il.t * Qbe_il.t option) -> Anf.block_scan -> int ->
  Qbe_il.t list -> Qbe_il.t
