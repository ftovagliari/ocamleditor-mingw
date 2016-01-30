(*

  OCamlEditor
  Copyright (C) 2010-2014 Francesco Tovagliari

  This file is part of OCamlEditor.

  OCamlEditor is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  OCamlEditor is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program. If not, see <http://www.gnu.org/licenses/>.

*)


open Printf
open Oebuild_util

module Table = Oebuild_table

type compilation_type = Bytecode | Native | Unspecified
type output_type = Executable | Library | Plugin | Pack | External
type build_exit = Built_successfully | Build_failed of int
type process_err_func = (in_channel -> unit)

let string_of_compilation_type = function
  | Bytecode -> "Bytecode"
  | Native -> "Native"
  | Unspecified -> "Unspecified"

let string_of_output_type = function
  | Executable -> "Executable"
  | Library -> "Library"
  | Plugin -> "Plugin"
  | Pack -> "Pack"
  | External -> "External";;

let ocamlc = Ocaml_config.ocamlc()
let ocamlopt = Ocaml_config.ocamlopt()
let ocamllib = Ocaml_config.ocamllib()

(** check_package_list *)
let check_package_list =
  let redirect_stderr = if Sys.os_type = "Win32" then " 1>NUL 2>NUL" else " 1>/dev/null 2>/dev/null" in
  fun package_list ->
    let package_list = Str.split (Str.regexp "[, ]") package_list in
    let available, unavailable =
      List.partition begin fun package ->
        kprintf (Oebuild_util.command ~echo:false) "ocamlfind query %s %s" package redirect_stderr = 0
      end package_list
    in
    if unavailable <> [] then begin
      eprintf "Warning (oebuild): the following packages are not found: %s\n"
        (String.concat ", " unavailable);
    end;
    String.concat "," available;;

(** get_compiler_command *)
let get_compiler_command ?(times : Table.t option) ~opt ~compiler ~cflags ~includes ~filename ~verbose () =
  if Sys.file_exists filename then begin
    try
      begin
        match times with
          | Some times ->
            ignore (Table.find times filename opt);
            None
          | _ -> raise Not_found
      end
    with Not_found -> begin
        let verbose_opt = if verbose >= 5 then "-verbose" else "" in
        let compiler, args = compiler in
        Some (compiler, Array.concat [
            [| "-c"; |] ;
            args;
            (Array.of_list (Str.split re_spaces cflags));
            (Array.of_list (Str.split re_spaces includes));
            [| verbose_opt; filename |]
          ])
      end
  end else None

(** compile *)
let compile ?(times : Table.t option) ~opt ~compiler ~cflags ~includes ~filename
    ?(process_err : process_err_func option) ~verbose () =
  let command = get_compiler_command ?times ~opt ~compiler ~cflags ~includes ~filename ~verbose () in
  match command with
    | Some (cmd, args) ->
      let exit_code =
        let cmd_line = String.concat " " (cmd :: (Array.to_list args)) in
        match process_err with
          | None -> Oebuild_util.command ~echo:(verbose >= 2) cmd_line
          | Some process_err ->
            begin
              let process_err = Spawn.loop process_err in
              if verbose >= 2 then print_endline cmd_line;
              match Spawn.sync ~process_err cmd args with
                | None -> 0
                | Some _ -> -99981
            end;
      in
      may times (fun times -> Table.add times filename opt (Unix.gettimeofday()));
      exit_code
    | _ -> 0
(* OLD VERSION
let compile ?(times : Table.t option) ~opt ~compiler ~cflags ~includes ~filename
    ?(process_err : process_err_func option) ~verbose () =
  if Sys.file_exists filename then begin
    try
      begin
        match times with
          | Some times -> ignore (Table.find times filename opt); 0 (* exit code *)
          | _ -> raise Not_found
      end
    with Not_found -> begin
      let verbose_opt = if verbose >= 5 then "-verbose" else "" in
      let cmd = (sprintf "%s -c %s %s %s %s" compiler cflags includes filename verbose_opt) in
      let exit_code =
        match process_err with
          | None -> command cmd
          | Some process_err ->
            begin
              match exec ~process_err ~verbose:(verbose>=2) cmd with
                | Some n -> n
                | None -> -9998
            end;
      in
      may times (fun times -> Table.add times filename opt (Unix.gettimeofday()));
      exit_code
    end
  end else 0*)

(** link *)
let link ~compilation ~compiler ~outkind ~lflags ~includes ~libs ~outname ~deps
    ?(process_err : process_err_func option) ~verbose () =
  let opt = compilation = Native && ocamlopt <> None in
  let libs =
    if (*opt &&*) outkind <> Executable then "" else
      let ext = if opt then "cmxa" else "cma" in
      let libs = List.map begin fun x ->
        if Filename.check_suffix x ".o" then begin
          let x = Filename.chop_extension x in
          let ext = if opt then "cmx" else "cmo" in
          sprintf "%s.%s" x ext
        end else if Filename.check_suffix x ".obj" then begin
          sprintf "%s" x
        end else (sprintf "%s.%s" x ext)
      end libs in
      String.concat " " libs
  in
  let deps = String.concat " " deps in
  let process_exit =
    let process_err = match process_err with Some f -> Some (Spawn.loop f) | _ -> None in
    let command, args = compiler in
    let args = Array.concat [
        args; (* Must be the first because starts with the first arg. of ocamlfind *)
        [|
          if verbose >= 5 then "-verbose" else "";
          (match outkind with Library -> "-a" | Plugin when opt -> "-shared" | Plugin -> "" | Pack -> "-pack" | Executable | External -> "");
          "-o";
          outname
        |];
        (Array.of_list (split_space lflags));
        (Array.of_list (split_space includes));
        (Array.of_list (split_space libs));
        (Array.of_list (split_space deps));
      ] in
    if verbose >= 2 then print_endline (String.concat " " (command :: (Array.to_list args)));
    Spawn.sync ?process_err command args
  in
  match process_exit with
    | None -> 0
    | Some ex -> -9997
;;

(** get_output_name *)
let get_output_name ~compilation ~outkind ~outname ?(dontaddopt=false) () =
    let o_ext =
      match outkind with
        | Library when compilation = Native -> ".cmxa"
        | Library -> ".cma"
        | Executable when compilation = Native && dontaddopt -> win32 ".exe" ""
        | Executable when compilation = Native -> ".opt" ^ (win32 ".exe" "")
        | Executable -> win32 ".exe" ""
        | Plugin when compilation = Native -> ".cmxs"
        | Plugin -> ".cma"
        | Pack -> ".cmx"
        | External -> ""
    in
    let name =
      if outname = "" then "a" (*begin
        match (List.rev toplevel_modules) with
          | last :: _ -> Filename.chop_extension last
          | _ -> assert false
      end*) else unquote outname
    in
    name ^ o_ext
;;

(** install *)
let install ~compilation ~outkind ~outname ~deps ~path ~ccomp_type =
  let dest_outname = Filename.basename outname in
  match outkind with
    | Library ->
      let path =
        let path = ocamllib // path in
        mkdir_p path;
        path
      in
      cp outname (path // dest_outname);
      let deps_mod = List.map Filename.chop_extension deps in
      let deps_mod = remove_dupl deps_mod in
      let cmis = List.map (fun d -> sprintf "%s.cmi" d) deps_mod in
      let mlis = List.map (fun cmi -> sprintf "%s.mli" (Filename.chop_extension cmi)) cmis in
      let mlis = List.filter Sys.file_exists mlis in
      List.iter (fun x -> ignore (cp x (path // (Filename.basename x)))) cmis;
      List.iter (fun x -> ignore (cp x (path // (Filename.basename x)))) mlis;
      if compilation = Native then begin
        let ext = match ccomp_type with Some "msvc" -> ".lib" | Some _ ->  ".a" | None -> assert false in
        let basename = sprintf "%s%s" (Filename.chop_extension outname) ext in
        cp basename (path // (Filename.basename basename));
      end;
    | Executable (*->
      mkdir_p path;
      cp outname (path // dest_outname)*)
    | Plugin | Pack | External -> eprintf "\"Oebuild.install\" not implemented for Executable, Plugin, Pack or External."
;;

(** run_output *)
let run_output ~outname ~args =
  let args = List.rev args in
  if Sys.win32 then begin
    let cmd = Str.global_replace (Str.regexp "/") "\\\\" outname in
    let cmd = Filename.current_dir_name // cmd in

    (*let args = cmd :: args in
    let args = Array.of_list args in
    Unix.execv cmd args*)

    (*let args = String.concat " " args in
    ignore (kprintf command "%s %s" cmd args)*)

    Spawn.sync
      ~process_in:Spawn.redirect_to_stdout ~process_err:Spawn.redirect_to_stderr
      cmd (Array.of_list args) |> ignore

  end else begin
    let cmd = Filename.current_dir_name // outname in
    (* From the execv manpage:
      "The first argument, by convention, should point to the filename associated
       with the file being executed." *)
    let args = cmd :: args in
    let args = Array.of_list args in
    Unix.execv cmd args
  end
;;

(** sort_dependencies *)
let sort_dependencies ~deps subset =
  let result = ref [] in
  List.iter begin fun x ->
    if List.mem x subset then (result := x :: !result)
  end deps;
  List.rev !result
;;

(** filter_inconsistent_assumptions_error *)
let filter_inconsistent_assumptions_error ~compiler_output ~recompile ~toplevel_modules ~deps ~(cache : Table.t) ~opt =
  let re_inconsistent_assumptions = Str.regexp
    ".*make[ \t\r\n]+inconsistent[ \t\r\n]+assumptions[ \t\r\n]+over[ \t\r\n]+\\(interface\\|implementation\\)[ \t\r\n]+\\([^ \t\r\n]+\\)[ \t\r\n]+"
  in
  let re_error = Str.regexp "Error: " in
  ((fun stderr ->
    let line = input_line stderr in
    Buffer.add_string compiler_output (line ^ "\n");
    let messages = Buffer.contents compiler_output in
    let len = String.length messages in
    try
      let pos = Str.search_backward re_error messages len in
      let last_error = String.sub messages pos (len - pos) in
      begin
        try
          let _ = Str.search_backward re_inconsistent_assumptions last_error (String.length last_error) in
          let modname = Str.matched_group 2 last_error in
          let dependants = Oebuild_dep.find_dependants ~path:(List.map Filename.dirname toplevel_modules) ~modname in
          let dependants = sort_dependencies ~deps dependants in
          let _ (*original_error*) = Buffer.contents compiler_output in
          eprintf "Warning (oebuild): the following files make inconsistent assumptions over interface/implementation %s: [%s]\n%!"
            modname (String.concat "; " dependants);
          List.iter begin fun filename ->
            Table.remove cache filename opt;
            let basename = Filename.chop_extension filename in
            let cmi = basename ^ ".cmi" in
            if Sys.file_exists cmi then (Sys.remove cmi);
            let cmo = basename ^ ".cmo" in
            if Sys.file_exists cmo then (Sys.remove cmo);
            let cmx = basename ^ ".cmx" in
            if Sys.file_exists cmx then (Sys.remove cmx);
            let obj = basename ^ (win32 ".obj" ".o") in
            if Sys.file_exists obj then (Sys.remove obj);
          end dependants;
          recompile := dependants;
        with Not_found -> ()
      end
    with Not_found -> ()) : process_err_func)
;;

(** serial_compile *)
let serial_compile ~compilation ~times ~compiler ~cflags ~includes ~toplevel_modules ~deps ~verbose =
  let crono = if verbose >= 3 then crono else fun ?label f x -> f x in
  let compilation_exit = ref 0 in
  begin
    try
      let opt = compilation = Native in
      let compiler_output = Buffer.create 100 in
      let rec try_compile filename =
        let recompile = ref [] in
        let compile_exit =
          Table.update ~opt times filename |> ignore;
          let exit_code =
            compile
              ~process_err:(filter_inconsistent_assumptions_error ~compiler_output ~recompile ~toplevel_modules ~deps ~cache:times ~opt)
              ~times ~opt ~compiler ~cflags ~includes ~filename ~verbose ()
          in
          if exit_code <> 0 then (Table.remove times filename opt);
          exit_code
        in
        if List.length !recompile > 0 then begin
          List.iter begin fun filename ->
            compilation_exit := compile ~times ~opt ~compiler ~cflags ~includes ~filename ~verbose ();
            if !compilation_exit <> 0 then (raise Exit)
          end !recompile;
          print_newline();
          Buffer.clear compiler_output;
          try_compile filename;
        end else begin
          if Buffer.length compiler_output > 0 then (eprintf "%s\n%!" (Buffer.contents compiler_output));
          compile_exit
        end
      in
      crono ~label:"Serial compilation" (List.iter begin fun filename ->
        compilation_exit := try_compile filename;
        if !compilation_exit <> 0 then (raise Exit)
      end) deps;
    with Exit -> ()
  end;
  !compilation_exit

(** parallel_compile *)
let parallel_compile ~compilation ?times ~compiler ~cflags ~includes ~toplevel_modules ~verbose ?jobs () =
  let crono = if verbose >= 3 then crono else fun ?label f x -> f x in
  let crono4 = if verbose >= 4 then crono else fun ?label f x -> f x in
  let open Oebuild_parallel in
  let opt = compilation = Native in
  let may_update_times = match times with Some times -> fun filename -> Table.update ~opt times filename |> ignore | _ -> ignore in
  let cb_create_command filename =
    may_update_times filename;
    get_compiler_command ?times ~opt ~compiler ~cflags ~includes ~filename ~verbose ()
  in
  let cb_at_exit out =
    may times begin fun times ->
      if out.exit_code = 0
      then Table.add times out.filename opt (Unix.gettimeofday())
      else Table.remove times out.filename opt;
    end
  in
  let times = match times with Some t -> Some (t, opt) | _ -> None in
  let dag = crono4 ~label:"Oebuild_parallel.create_dag (ocamldep+add+reduce)" (fun () ->
      Oebuild_parallel.create_dag ?times ~cb_create_command ~cb_at_exit ~toplevel_modules ~verbose ()) ()
  in
  crono ~label:"Parallel compilation" (Oebuild_parallel.process_parallel ?jobs ~verbose) dag;
  let sorted_deps = Oebuild_dep.sort_dependencies dag.ocamldeps in
  let deps_ml = List.map replace_extension_to_ml sorted_deps in
  sorted_deps, deps_ml, 0

(** Build *)
let build ~compilation ~package ~includes ~libs ~other_mods ~outkind ~compile_only
    ~thread ~vmthread ~annot ~bin_annot ~pp ?inline ~cflags ~lflags ~outname ~deps ~dontlinkdep ~dontaddopt (*~ms_paths*)
    ~toplevel_modules ?(jobs=0) ?(serial=false) ?(prof=false) ?(verbose=2) () =

  let crono = if verbose >= 3 then crono else fun ?label f x -> f x in
  let crono4 = if verbose >= 4 then crono else fun ?label f x -> f x in
  let libs = unquote libs in
  let cflags = unquote cflags in
  let lflags = unquote lflags in
  let includes = unquote includes in
  let package = unquote package in

  if verbose >= 1 then begin
    printf "\n%s %s" (string_of_compilation_type compilation) (string_of_output_type outkind);
    if outname <> ""    then (printf " %s\n" outname);
    if dontlinkdep      then (printf "  ~dontlinkdep\n");
    if dontaddopt       then (printf "  ~dontaddopt\n");
    if compile_only     then (printf "  ~compile_only\n");
    if thread           then (printf "  ~thread\n");
    if vmthread         then (printf "  ~vmthread\n");
    if bin_annot        then (printf "  ~binannot\n");
    if package <> ""    then (printf "  ~package ........ : %s\n" package);
    if includes <> ""   then (printf "  ~search_path .... : %s\n" includes);
    if libs <> ""       then (printf "  ~libs ........... : %s\n" libs);
    if other_mods <> "" then (printf "  ~other_mods ..... : %s\n" other_mods);
    (match inline with Some n ->
                              printf "  ~inline ......... : %d\n" n | _ -> ());
    if cflags <> ""     then (printf "  ~cflags ......... : %s\n" cflags);
    if lflags <> ""     then (printf "  ~lflags ......... : %s\n" cflags);
    if toplevel_modules <> []
                        then (printf "  ~toplevel_modules : %s\n" (String.concat "," toplevel_modules));
    if serial           then (printf "  ~serial ......... : %b\n" serial)
                        else (printf "  ~jobs ........... : %d\n" jobs);
    printf "  ~verbose ........ : %d\n" verbose;
    if verbose >= 2 then (printf "\n");
    printf "%!";
  end;
  (* includes *)
  let includes = ref includes in
  includes := Ocaml_config.expand_includes !includes;
  (* libs *)
  let libs = split_space libs in
  (* flags *)
  let cflags = ref cflags in
  let lflags = ref lflags in
  (* thread *)
  if thread then (cflags := !cflags ^ " -thread"; lflags := !lflags ^ " -thread");
  if vmthread then (cflags := !cflags ^ " -vmthread"; lflags := !lflags ^ " -vmthread");
  if annot then (cflags := !cflags ^ " -annot");
  if bin_annot then (cflags := !cflags ^ " -bin-annot");
  if pp <> "" then (cflags := !cflags ^ " -pp " ^ pp);
  (* inline *)
  begin
    match inline with
      | Some inline when compilation = Native ->
        let inline = string_of_int inline in
        cflags := !cflags ^ " -inline " ^ inline;
        lflags := !lflags ^ " -inline " ^ inline;
      | _ -> ()
  end;
  (* Get compiler and linker names *)
  let package = check_package_list package in
  let compiler, linker =
    if prof then ("ocamlcp", [|"-p"; "a"|]), ("ocamlcp", [|"-p"; "a"|])
    else begin
      let ocaml_c_opt =
        if compilation = Native then
          (match ocamlopt with Some x -> x | _ -> failwith "ocamlopt was not found")
        else ocamlc
      in
      let use_findlib = package <> "" in
      if use_findlib then
        let thread = if thread then "-thread" else if vmthread then "-vmthread" else "" in
        let ocaml_c_opt = if String.contains ocaml_c_opt '.' then String.sub ocaml_c_opt 0 (String.index ocaml_c_opt '.') else ocaml_c_opt in
        let ocamlfind = sprintf "ocamlfind %s -package %s %s" ocaml_c_opt package thread in
        let compiler_args = crono4 ~label:"Oebuild, get_effective_command(compiler)" get_effective_command ocamlfind in
        let linker_args =
          if compile_only then "", [||] else
            let linkpkg = outkind <@ [Executable] in
            let cmd = if linkpkg then ocamlfind ^ " -linkpkg" else ocamlfind in
            split_prog_args cmd
            (*crono ~label:"Oebuild, get_effective_command(linker)" (get_effective_command ~linkpkg) ocamlfind*)
        in
        compiler_args, linker_args
      else split_prog_args ocaml_c_opt, split_prog_args ocaml_c_opt
    end
  in
  (*  *)
  let times = Table.read () in
  let build_exit =
    (** Compile *)
    let deps, deps_ml, compilation_exit =
      if serial
      then
        let deps_ml = List.map replace_extension_to_ml deps in
        deps, deps_ml, serial_compile ~compilation ~times ~compiler ~cflags:!cflags ~includes:!includes ~toplevel_modules ~deps:deps_ml ~verbose
      else parallel_compile ~compilation ~times ~compiler ~cflags:!cflags ~includes:!includes ~toplevel_modules ~verbose ~jobs ()
    in
    (*if verbose >= 4 then Printf.printf "SORTED DEPENDENCIES:\n[%s]\n\n%!" (String.concat "; " deps);*)
    (** Link *)
    if compilation_exit = 0 then begin
      let opt = compilation = Native in
      let find_objs filenames =
        let objs = List.filter (fun x -> x ^^ ".cmx") filenames in
        if opt then objs else List.map (fun x -> (Filename.chop_extension x) ^ ".cmo") objs
      in
      let mods = split_space other_mods in
      let mods = if compilation = Native then List.map (sprintf "%s.cmx") mods else List.map (sprintf "%s.cmo") mods in
      let obj_deps =
        if dontlinkdep then
          find_objs (List.map (fun ml ->
              if ml ^^ ".ml"
              then (Filename.chop_extension ml) ^ ".cmx"
              else if ml ^^ ".mli" then (Filename.chop_extension ml) ^ ".cmi"
              else ml) toplevel_modules)
        else mods @ (find_objs deps)
      in
      if compile_only then compilation_exit else begin
        let compiler_output = Buffer.create 100 in
        let rec try_link () =
          let recompile = ref [] in
          let link_exit =
            crono ~label:"Linking phase" (link ~compilation ~compiler:linker ~outkind ~lflags:!lflags
              ~includes:!includes ~libs ~deps:obj_deps ~outname
              ~process_err:(filter_inconsistent_assumptions_error ~compiler_output ~recompile ~toplevel_modules ~deps:deps_ml ~cache:times ~opt)
              ~verbose) ()
          in
          if List.length !recompile > 0 then begin
            if serial then begin
              crono ~label:"Serial compilation" (List.iter begin fun filename ->
                  ignore (compile ~times ~opt ~compiler ~cflags:!cflags ~includes:!includes ~filename ~verbose ())
                end) !recompile;
            end else begin
              parallel_compile ~compilation ~times ~compiler ~cflags:!cflags ~includes:!includes ~toplevel_modules ~verbose ~jobs () |> ignore
            end;
            Buffer.clear compiler_output;
            try_link()
          end else begin
            if Buffer.length compiler_output > 0 then eprintf "%s\n%!" (Buffer.contents compiler_output);
            link_exit
          end
        in
        try_link()
      end
    end else compilation_exit
  in
  Table.write times;
  if build_exit = 0 && not compile_only then begin
    if verbose >= 1 then begin
      Printf.printf "\n%s %s\n%!" (string_of_compilation_type compilation) (string_of_output_type outkind);
      let result =
        [((Sys.getcwd()) // outname), (format_int (Unix.stat outname).Unix.st_size)]
        @
        match compilation with
          | Native when outkind = Library ->
            List.flatten (List.map begin fun ext ->
              let filename = (Sys.getcwd()) // ((Filename.chop_extension outname) ^ ext) in
              if Sys.file_exists filename then
                [filename, (format_int (Unix.stat filename).Unix.st_size)]
              else []
            end [".lib"; ".a"])
          | Bytecode | Unspecified | Native -> []
      in
      List.iter (Printf.printf "%s\n%!") (dot_leaders ~right_align:true ~postfix:" bytes" result);
    end;
    Built_successfully
  end else (Build_failed build_exit)
;;

(** clean *)
let obj_extensions = [".cmi"; ".cmo"; ".cmx"; ".o"; ".obj"; ".annot"; ".cmt"; ".cmti"]
let lib_extensions = [".cma"; ".cmxa"; ".lib"; ".a"; ".dll"]

let clean ~deps () =
  let files = List.map begin fun name ->
    let name = Filename.chop_extension name in
    List.map ((^) name) obj_extensions
  end deps in
  let files = List.flatten files in
  (*let files = if outkind = Executable || all then (match outname with Some x -> x :: files | _ -> files) else files in*)
  let files = remove_dupl files in
  List.iter (fun file -> remove_file ~verbose:false file) files
;;

(** distclean - doesn't remove executables *)
let distclean () =
  let cwd = Sys.getcwd() in
  let exists_with_suffix sufs name = List.exists (fun suf -> name ^^ suf) sufs in
  let rec clean_dir dir =
    if not ((Unix.lstat dir).Unix.st_kind = Unix.S_LNK) then begin
      let files = Sys.readdir dir in
      let files = Array.to_list files in
      let files = List.map (fun x -> dir // x) files in
      let directories, files = List.partition Sys.is_directory files in
      let files = List.filter (exists_with_suffix (obj_extensions @ lib_extensions)) files in
      List.iter (remove_file ~verbose:false) files;
      let oebuild_times_filename = dir // Table.oebuild_times_filename in
      remove_file ~verbose:false oebuild_times_filename;
      List.iter clean_dir directories;
    end
  in
  clean_dir cwd;
;;

let re_fl_pkg_exist = Str.regexp "\\(HAVE_FL_PKG\\|FINDLIB\\)(\\([-A-Za-z0-9_., ]+\\))"

let s_prop_body = "\\(\\([A-Za-z0-9_-]+\\)\\(=\\|<>\\|!=\\|:\\)\\(.*\\)\\)"
let re_prop_body = Str.regexp s_prop_body
let re_env = Str.regexp ("ENV(" ^ s_prop_body ^ ")")
let re_ocfg = Str.regexp ("OCAML(" ^ s_prop_body ^ ")")

let re_comma = Str.regexp " *, *"

let check_prop expr get =
  (*
     [1] ENV(NAME)        <=> NAME is defined
     [2] ENV(NAME=VALUE)  <=> NAME is defined and is equal to VALUE
     [3] ENV(NAME<>VALUE) <=> NAME is defined and is not equal to VALUE or NAME is not defined
     [4] ENV()            <=> false
  *)
  try
    let name = String.trim (Str.matched_group 2 expr) in
    let op, is_eq =
      try
        let gr = Str.matched_group 3 expr in
        if gr = "=" || gr = ":" then Some (=), true else Some (<>), false
      with Not_found -> None, false
    in
    begin
      match op with
        | Some op ->
          let value = try String.trim (Str.matched_group 4 expr) with Not_found -> "" in
          (try op (get name) value (* [2] *) with Not_found (* name is not defined. *) -> not is_eq) (* [3] *)
        | None -> (try get name |> ignore; true with Not_found -> false) (* [1] *)
    end;
  with Not_found (* name (matched_group) *) -> false (* [4] *)


(** check_restrictions *)
let check_restrictions restr =
  List.for_all begin function
    | "IS_UNIX" -> Sys.os_type = "Unix"
    | "IS_WIN32" -> Sys.os_type = "Win32"
    | "IS_CYGWIN" -> Sys.os_type = "Cygwin"
    | "HAVE_NATIVE" | "HAS_NATIVE" | "NATIVE" -> Ocaml_config.can_compile_native () <> None (* should be cached *)
    | res when Str.string_match re_env res 0 -> check_prop res Sys.getenv
    | res when Str.string_match re_ocfg res 0 -> check_prop res Ocaml_config.get
    | res when Str.string_match re_fl_pkg_exist res 0 ->
      let packages = Str.matched_group 2 res in
      let packages = Str.split re_comma packages in
      let redirect_stderr = if Sys.os_type = "Win32" then " 1>NUL 2>NUL" else " 1>/dev/null 2>/dev/null" in
      packages = [] || List.for_all begin fun package ->
        kprintf (Oebuild_util.command ~echo:false) "ocamlfind query %s %s" package redirect_stderr = 0
      end packages
    | _ -> false
  end restr;;
