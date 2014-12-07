
open Printf

let append l1 l2 =
  List.flatten (List.map (fun s1 -> List.map (fun s2 -> s1 ^ s2) l2) l1)

let get_file_list base =
  append (append [base] ["_t";"_b";"_j";"_v"]) [".mli";".ml"]

let print_file_list base =
  let l = get_file_list base in
  print_endline (String.concat " " l)

let print_deps base =
  let l = get_file_list base in
  List.iter (fun out -> printf "%s: %s.atd\n" out base) l;
  flush stdout

let set_once varname var x =
  match !var with
      Some y ->
        if x <> y then
          failwith (sprintf "\
Command-line parameter %S is set multiple times
to incompatible values."
                      varname)

    | None ->
        var := Some x

type mode =
    [ `T (* -t (type defs and create_* functions) *)
    | `B (* -b (biniou serialization) *)
    | `J (* -j (json serialization) *)
    | `V (* -v (validators) *)
    | `Dep (* -dep (print all file dependencies produced by -t -b -j -v) *)
    | `List (* -list (list all files produced by -t -b -j -v) *)

    | `Biniou (* -biniou (deprecated) *)
    | `Json (* -json (deprecated) *)
    | `Validate (* -validate (deprecated) *)
    ]

let parse_ocaml_version () =
  let re = Str.regexp "^\\([0-9]+\\)\\.\\([0-9]+\\)" in
  if Str.string_match re Sys.ocaml_version 0 then
    let major = Str.matched_group 1 Sys.ocaml_version in
    let minor = Str.matched_group 2 Sys.ocaml_version in
    Some (int_of_string major, int_of_string minor)
  else
    None

let get_default_name_overlap () =
  match parse_ocaml_version () with
  | Some (major, minor) when major < 4 -> false
  | Some (4, 0) -> false
  | _ -> true

let main () =
  let pos_fname = ref None in
  let pos_lnum = ref None in
  let files = ref [] in
  let opens = ref [] in
  let with_typedefs = ref None in
  let with_create = ref None in
  let with_fundefs = ref None in
  let all_rec = ref false in
  let out_prefix = ref None in
  let mode = ref (None : mode option) in
  let std_json = ref false in
  let j_preprocess_input = ref None in
  let j_defaults = ref false in
  let unknown_field_handler = ref None in
  let constr_mismatch_handler = ref None in
  let type_aliases = ref None in
  let name_overlap = ref (get_default_name_overlap ()) in
  let set_opens s =
    let l = Str.split (Str.regexp " *, *\\| +") s in
    opens := List.rev_append l !opens
  in
  let options = [
    "-t", Arg.Unit (fun () ->
                      set_once "output type" mode `T;
                      set_once "no function definitions" with_fundefs false),
    "
          Produce files example_t.mli and example_t.ml
          containing OCaml type definitions derived from example.atd.";

    "-b", Arg.Unit (fun () -> set_once "output type" mode `B),
    "
          Produce files example_b.mli and example_b.ml
          containing OCaml serializers and deserializers for the Biniou
          data format from the specifications in example.atd.";

    "-j", Arg.Unit (fun () -> set_once "output type" mode `J),
    "
          Produce files example_j.mli and example_j.ml
          containing OCaml serializers and deserializers for the JSON
          data format from the specifications in example.atd.";

    "-v", Arg.Unit (fun () -> set_once "output type" mode `V),
    "
          Produce files example_v.mli and example_v.ml
          containing OCaml functions for creating records and
          validators from the specifications in example.atd.";

    "-dep", Arg.Unit (fun () -> set_once "output type" mode `Dep),
    "
          Output Make-compatible dependencies for all possible
          products of atdgen -t, -b, -j and -v, and exit.";

    "-list", Arg.Unit (fun () -> set_once "output type" mode `List),
    "
          Output a space-separated list of all possible products of
          atdgen -t, -b, -j and -v, and exit.";

    "-o", Arg.String (fun s ->
                        let out =
                          match s with
                              "-" -> `Stdout
                            | s -> `Files s
                        in
                        set_once "output prefix" out_prefix out),
    "[ PREFIX | - ]
          Use this prefix for the generated files, e.g. 'foo/bar' for
          foo/bar.ml and foo/bar.mli.
          `-' designates stdout and produces code of the form
            struct ... end : sig ... end";

    "-biniou",
    Arg.Unit (fun () ->
                set_once "output type" mode `Biniou),
    "
          [deprecated in favor of -t and -b]
          Produce serializers and deserializers for Biniou
          including OCaml type definitions (default).";

    "-json",
    Arg.Unit (fun () ->
                set_once "output type" mode `Json),
    "
          [deprecated in favor of -t and -j]
          Produce serializers and deserializers for JSON
          including OCaml type definitions.";

    "-j-std",
    Arg.Unit (fun () ->
                std_json := true),
    "
          Convert tuples and variants into standard JSON and
          refuse to print NaN and infinities (implying -json mode
          unless another mode is specified).";

    "-std-json",
    Arg.Unit (fun () ->
                std_json := true),
    "
          [deprecated in favor of -j-std]
          Same as -j-std.";

    "-j-pp",
    Arg.String (fun s -> set_once "-j-pp" j_preprocess_input s),
    "<func>
          OCaml function of type (string -> string) applied on the input
          of each *_of_string function generated by atdgen (JSON mode).
          This is originally intended for UTF-8 validation of the input
          which is not performed by atdgen.";

    "-j-defaults",
    Arg.Set j_defaults,
    "
          Output JSON record fields even if their value is known
          to be the default.";

    "-j-strict-fields",
    Arg.Unit (
      fun () ->
        set_once "unknown field handler" unknown_field_handler
          "!Ag_util.Json.unknown_field_handler"
    ),
    "
          Call !Ag_util.Json.unknown_field_handler for every unknown JSON field
          found in the input instead of simply skipping them.
          The initial behavior is to raise an exception.";

    "-j-custom-fields",
    Arg.String (
      fun s ->
        set_once "unknown field handler" unknown_field_handler s
    ),
    "FUNCTION
          Call the given function of type (string -> unit)
          for every unknown JSON field found in the input
          instead of simply skipping them.
          See also -j-strict-fields.";

    "-j-strict-constrs",
    Arg.Unit (
      fun () ->
        set_once "constructor mismatch handler" constr_mismatch_handler
          "!Ag_util.Json.constr_mismatch_handler"
    ),
    "
          Given a record type of the form
          { t: string; v <json tag_field=\"t\">: v },
          this option allows the user to define a runtime conflict handler.
          A conflict occurs when trying to serialize an OCaml record
          such as { t = \"A\"; v = `B } into JSON.
          A correct record might be { t = \"B\"; v = `B }
          or { t = \"A\"; v = `A 123 }.

          With this option, !Ag_util.Json.constr_mismatch_handler is called
          for every mismatched constructor field value and value
          field constructor in the data structures to output instead
          of simply serializing them.
          The initial behavior is to raise an exception.";

    "-validate",
    Arg.Unit (fun () ->
                set_once "output type" mode `Validate),
    "
          [deprecated in favor of -t and -v]
          Produce data validators from <ocaml validator=\"x\"> annotations
          where x is a user-written validator to be applied on a specific
          node.
          This is typically used in conjunction with -extend because
          user-written validators depend on the type definitions.";

    "-extend", Arg.String (fun s -> type_aliases := Some s),
    "MODULE
          Assume that all type definitions are provided by the specified
          module unless otherwise annotated. Type aliases are created
          for each type, e.g.
            type t = Module.t";

    "-open", Arg.String set_opens,
    "MODULE1,MODULE2,...
          List of modules to open (comma-separated or space-separated)";

    "-nfd", Arg.Unit (fun () ->
                        set_once "no function definitions" with_fundefs false),
    "
          Do not dump OCaml function definitions";

    "-ntd", Arg.Unit (fun () ->
                        set_once "no type definitions" with_typedefs false),
    "
          Do not dump OCaml type definitions";

    "-pos-fname", Arg.String (set_once "pos-fname" pos_fname),
    "FILENAME
          Source file name to use for error messages
          (default: input file name)";

    "-pos-lnum", Arg.Int (set_once "pos-lnum" pos_lnum),
    "LINENUM
          Source line number of the first line of the input (default: 1)";

    "-rec", Arg.Set all_rec,
    "
          Keep OCaml type definitions mutually recursive";

    "-o-name-overlap", Arg.Set name_overlap,
    "
          Accept records and classic (non-polymorphic) variants with identical
          field or constructor names in the same module. Overlapping names are
          supported in OCaml since version 4.01.

          Duplicate name checking will be skipped, and type annotations will
          be included in the implementation to disambiguate names.
          This is the default if atdgen was compiled for OCaml >= 4.01.0";

    "-o-no-name-overlap", Arg.Clear name_overlap,
    "
          Disallow records and classic (non-polymorphic) variants
          with identical field or constructor names in the same module.
          This is the default if atdgen was compiled for OCaml < 4.01.0";

    "-version",
    Arg.Unit (fun () ->
                print_endline Ag_version.version;
                exit 0),
    "
          Print the version identifier of atdgen and exit.";
  ]
  in
  let msg = sprintf "\
Generate OCaml code offering:
  * OCaml type definitions translated from ATD file (-t)
  * serializers and deserializers for Biniou (-b)
  * serializers and deserializers for JSON (-j)
  * record-creating functions supporting default fields (-v)
  * user-specified data validators (-v)

Recommended usage: %s (-t|-b|-j|-v|-dep|-list) example.atd" Sys.argv.(0) in
  Arg.parse options (fun file -> files := file :: !files) msg;

  if (!std_json
      || !unknown_field_handler <> None
      || !constr_mismatch_handler <> None) && !mode = None then
    set_once "output mode" mode `Json;

  let mode =
    match !mode with
        None -> `Biniou
      | Some x -> x
  in

  let with_create =
    match !with_create with
        Some x -> x
      | None ->
          match mode with
              `T | `B | `J -> false
            | `V -> true
            | `Biniou | `Json | `Validate -> true
            | `Dep | `List -> true (* don't care *)
  in

  let force_defaults =
    match mode with
        `J | `Json -> !j_defaults
      | `T
      | `B | `Biniou
      | `V | `Validate
      | `Dep | `List -> false (* don't care *)
  in

  let atd_file =
    match !files with
        [s] -> Some s
      | [] -> None
      | _ ->
          Arg.usage options msg;
          exit 1
  in
  let base_ocaml_prefix =
    match !out_prefix, atd_file with
        Some x, _ -> x
      | None, Some file ->
          `Files (
              if Filename.check_suffix file ".atd" then
                Filename.chop_extension file
              else
                file
          )
      | None, None -> `Stdout
  in
  let base_prefix, ocaml_prefix =
    match base_ocaml_prefix with
        `Stdout -> None, `Stdout
      | `Files base ->
          Some base, `Files
            (match mode with
                 `T -> base ^ "_t"
               | `B -> base ^ "_b"
               | `J -> base ^ "_j"
               | `V -> base ^ "_v"
               | _ -> base
            )
  in
  let type_aliases =
    match base_prefix with
        None ->
          (match mode with
               `B | `J | `V -> Some "T"
             | _ -> None
          )
      | Some base ->
          match !type_aliases with
              Some _ as x -> x
            | None ->
                (match mode with
                     `B | `J | `V ->
                       Some (String.capitalize (Filename.basename base) ^ "_t")
                   | _ -> None
          )
  in
  let get_base_prefix () =
    match base_prefix with
        None -> failwith "Undefined output file names"
      | Some s -> s
  in
  match mode with
      `Dep -> print_deps (get_base_prefix ())
    | `List -> print_file_list (get_base_prefix ())
    | `T | `B | `J | `V | `Biniou | `Json | `Validate ->

        let opens = List.rev !opens in
        let make_ocaml_files =
          match mode with
              `T ->
                Ag_ob_emit.make_ocaml_files
            | `B | `Biniou ->
                Ag_ob_emit.make_ocaml_files
            | `J | `Json ->
                Ag_oj_emit.make_ocaml_files
                  ~std: !std_json
                  ~unknown_field_handler: !unknown_field_handler
                  ~constr_mismatch_handler: !constr_mismatch_handler
                  ~preprocess_input: !j_preprocess_input
            | `V | `Validate ->
                Ag_ov_emit.make_ocaml_files
            | _ -> assert false
        in
        let with_default default = function None -> default | Some x -> x in

        make_ocaml_files
          ~opens
          ~with_typedefs: (with_default true !with_typedefs)
          ~with_create
          ~with_fundefs: (with_default true !with_fundefs)
          ~all_rec: !all_rec
          ~pos_fname: !pos_fname
          ~pos_lnum: !pos_lnum
          ~type_aliases
          ~force_defaults
          ~name_overlap: !name_overlap
          atd_file ocaml_prefix

let () =
  try main ()
  with
      Atd_ast.Atd_error s
    | Failure s ->
        flush stdout;
        eprintf "%s\n%!" s;
        exit 1
    | e -> raise e
