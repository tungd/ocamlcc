type sink = < contents : string; output : string -> int -> int -> int >

(* Construct the wire layout shared by OCaml objects and method calls. *)
let make_sink () : sink =
  let buffer self = (Obj.obj (Obj.field self 2) : Buffer.t) in
  let contents self = Buffer.contents (buffer self) in
  let output self text offset length =
    Buffer.add_substring (buffer self) text offset length;
    length
  in
  let methods = [|
    Oo.public_method_label "contents", Obj.repr contents;
    Oo.public_method_label "output", Obj.repr output;
  |] in
  Array.sort (fun (left, _) (right, _) -> compare left right) methods;
  let table = Array.make 6 (Obj.repr 0) in
  table.(0) <- Obj.repr 2;
  table.(1) <- Obj.repr (2 * (Sys.word_size / 8) - 1);
  Array.iteri (fun i (tag, meth) ->
    table.(2 + 2 * i) <- meth;
    table.(3 + 2 * i) <- Obj.repr tag) methods;
  let receiver = Obj.new_block Obj.object_tag 3 in
  Obj.set_field receiver 0 (Obj.repr table);
  Obj.set_field receiver 1 (Obj.repr 0);
  Obj.set_field receiver 2 (Obj.repr (Buffer.create 16));
  Obj.obj receiver

let write (out : < output : string -> int -> int -> int; .. >) text =
  out#output text 1 (String.length text - 2)

let () =
  let sink = make_sink () in
  assert (write sink "[arc]" = 3);
  let append = sink#output "arc-value" in
  assert (append 4 5 = 5);
  assert (sink#contents = "arcvalue");
  (match sink#output "x" 0 2 with
   | exception Invalid_argument _ -> ()
   | _ -> assert false);
  assert (sink#contents = "arcvalue");
  print_endline "object send: public method, partial application, exceptions"
