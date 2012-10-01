(*

  OCamlEditor
  Copyright (C) 2010-2012 Francesco Tovagliari

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
open GUtil
open Miscellanea
open Cmt_format
open Location
open Typedtree
open Asttypes
open Types

type kind =
  | Function
  | Simple
  | Class
  | Class_virtual
  | Class_type
  | Class_inherit
  | Attribute
  | Attribute_mutable
  | Attribute_mutable_virtual
  | Attribute_virtual
  | Initializer
  | Method
  | Method_private
  | Method_virtual
  | Method_private_virtual
  | Method_inherited
  | Type
  | Type_abstract
  | Type_variant
  | Type_record
  | Module
  | Module_functor
  | Module_type
  | Exception
  | Error
  | Warning
  | Folder_warnings
  | Folder_errors
  | Dependencies
  | Bookmark of GdkPixbuf.pixbuf
  | Class_let_bindings
  | Unknown

let pixbuf_of_kind = function
  | Function -> Some Icons.func
  | Simple -> Some Icons.simple
  | Method -> Some Icons.met
  | Method_private -> Some Icons.met_private
  | Method_virtual -> Some Icons.met_virtual
  | Method_private_virtual -> Some Icons.met_private_virtual
  | Method_inherited -> Some Icons.met
  | Initializer -> Some Icons.init
  | Attribute -> Some Icons.attribute
  | Attribute_mutable -> Some Icons.attribute_mutable
  | Attribute_mutable_virtual -> Some Icons.attribute_mutable_virtual
  | Attribute_virtual -> Some Icons.attribute_virtual
  | Type -> Some Icons.typ
  | Type_abstract -> Some Icons.type_abstract
  | Type_variant -> Some Icons.type_variant
  | Type_record -> Some Icons.type_record
  | Class -> Some Icons.classe
  | Class_virtual -> Some Icons.class_virtual
  | Class_type -> Some Icons.class_type
  | Class_inherit -> Some Icons.class_inherit
  | Module -> Some Icons.module_impl
  | Module_functor -> Some Icons.module_funct
  | Module_type -> Some Icons.module_type
  | Exception -> Some Icons.exc
  | Error -> Some Icons.error_14
  | Warning -> Some Icons.warning_14
  | Folder_warnings -> Some Icons.folder_warning
  | Folder_errors -> Some Icons.folder_error
  | Dependencies -> None
  | Bookmark pixbuf -> Some pixbuf
  | Class_let_bindings -> None
  | Unknown -> None;;

type info = {
  typ          : string;
  kind         : kind option;
  location     : Location.t option;
  (*body         : ;*)
  mutable mark : Gtk.text_mark option;
}

let cols         = new GTree.column_list
let col_icon     = cols#add (Gobject.Data.gobject_by_name "GdkPixbuf")
let col_name     = cols#add Gobject.Data.string
let col_markup   = cols#add Gobject.Data.string
let col_lazy : (unit -> unit) list GTree.column = cols#add Gobject.Data.caml

let string_of_loc loc =
  let filename, a, b = Location.get_pos_info loc.loc_start in
  let _, c, d = Location.get_pos_info loc.loc_end in
  sprintf "%s, %d:%d -- %d:%d" filename a b c d;;

let linechar_of_loc loc =
  let _, a, b = Location.get_pos_info loc.loc_start in
  let _, c, d = Location.get_pos_info loc.loc_end in
  ((a - 1), b), ((c - 1), d)

let is_function type_expr =
  let rec f t =
    match t.Types.desc with
      | Types.Tarrow _ -> true
      | Types.Tlink t -> f t
      | _ -> false
  in f type_expr;;

let string_of_type_expr te =
  match te.desc with
    | Tarrow (_, _, t2, _) -> Odoc_info.string_of_type_expr t2
    | _ -> Odoc_info.string_of_type_expr te;;

class widget ~editor ~page ?packing () =
  let show_types           = Preferences.preferences#get.Preferences.pref_outline_show_types in
  let vbox                 = GPack.vbox ?packing () in
  let toolbar              = GPack.hbox ~spacing:0 ~packing:vbox#pack ~show:true () in
  let button_refresh       = GButton.button ~relief:`NONE ~packing:toolbar#pack () in
  let button_show_types    = GButton.toggle_button ~active:show_types ~relief:`NONE ~packing:toolbar#pack () in
  let button_sort          = GButton.toggle_button ~relief:`NONE ~packing:toolbar#pack () in
  let button_sort_rev      = GButton.toggle_button ~relief:`NONE ~packing:toolbar#pack () in
  let button_select_struct = GButton.button ~relief:`NONE ~packing:toolbar#pack () in
  let button_select_buf    = GButton.button ~relief:`NONE ~packing:toolbar#pack () in
  let _                    = button_refresh#set_image (GMisc.image (*~stock:`REFRESH*) ~pixbuf:Icons.refresh14 ~icon_size:`MENU ())#coerce in
  let _                    = button_sort#set_image (GMisc.image (*~stock:`SORT_ASCENDING*) ~pixbuf:Icons.sort_asc ~icon_size:`MENU ())#coerce in
  let _                    = button_sort_rev#set_image (GMisc.image (*~stock:`SORT_DESCENDING*) ~pixbuf:Icons.sort_asc_rev ~icon_size:`MENU ())#coerce in
  let _                    = button_show_types#set_image (GMisc.image ~pixbuf:Icons.typ ())#coerce in
  let _                    = button_select_buf#set_image (GMisc.image ~pixbuf:Icons.select_in_buffer ())#coerce in
  let _                    = button_select_struct#set_image (GMisc.image ~pixbuf:Icons.select_in_structure ())#coerce in
  let _                    = button_sort#misc#set_tooltip_text "Sort by name" in
  let _                    = button_sort_rev#misc#set_tooltip_text "Sort by reverse name" in
  let _                    = button_show_types#misc#set_tooltip_text "Show types" in
  let _                    = button_select_struct#misc#set_tooltip_text "Select in Structure Pane" in
  let _                    = button_select_buf#misc#set_tooltip_text "Select in Buffer" in
  let _                    =
    button_show_types#misc#set_can_focus false;
    button_sort#misc#set_can_focus false;
    button_sort_rev#misc#set_can_focus false;
    button_select_struct#misc#set_can_focus false;
    button_select_buf#misc#set_can_focus false;
    button_refresh#misc#set_can_focus false;
  in
  let model                = GTree.tree_store cols in
  let sw                   = GBin.scrolled_window ~shadow_type:`IN ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~packing:vbox#add () in
  let view                 = GTree.view ~model ~headers_visible:false ~packing:sw#add ~width:350 ~height:500 () in
  let renderer_pixbuf      = GTree.cell_renderer_pixbuf [`YPAD 0; `XPAD 0] in
  let renderer_markup      = GTree.cell_renderer_text [`YPAD 0] in
  let vc                   = GTree.view_column () in
  let _                    = vc#pack ~expand:false renderer_pixbuf in
  let _                    = vc#pack ~expand:false renderer_markup in
  let _                    = vc#add_attribute renderer_pixbuf "pixbuf" col_icon in
  let _                    = vc#add_attribute renderer_markup "markup" col_markup in
  let _                    = view#selection#set_mode `SINGLE in
  let _                    = view#append_column vc in
  let _                    = view#misc#set_property "enable-tree-lines" (`BOOL true) in
  let _                    = view#misc#modify_font_by_name Preferences.preferences#get.Preferences.pref_compl_font in
  let _                    = view#misc#modify_base [`SELECTED, `NAME Oe_config.outline_selection_bg_color; `ACTIVE, `NAME Oe_config.outline_active_bg_color] in
  let _                    = view#misc#modify_text [`SELECTED, `NAME Oe_config.outline_selection_fg_color; `ACTIVE, `NAME Oe_config.outline_active_fg_color] in
  let type_color           = Oe_config.outline_type_color in
  let type_color_re        = Str.regexp_string type_color in
  let type_color_sel       = Color.name_of_gdk (view#misc#style#fg `SELECTED) in
  let type_color_sel_re    = Str.regexp_string type_color_sel in
  let span_type_color      = " <span color='" ^ type_color ^ "'>: " in
  let label_tooltip        = ref (GMisc.label ~markup:" " ()) in
  let buffer : Ocaml_text.buffer = page#buffer in
object (self)
  inherit GObj.widget vbox#as_widget

  val changed = new changed()
  val mutable last_selected_path = None
  val mutable signal_selection_changed = None
  val mutable timestamp = "", 0.0
  val mutable filename = ""
  val mutable table_collapsed_by_default = []
  val mutable table_expanded_by_user = []
  val mutable table_expanded_by_default = []
  val table_info = Hashtbl.create 17
  val mutable selected_path = None

  initializer
    (** Replace foreground color when row is selected *)
    let replace_color_in_markup (model : GTree.tree_store) invert path =
      let row = model#get_iter path in
      let markup = model#get ~row ~column:col_markup in
      let new_markup = if invert then begin
        Str.replace_first type_color_sel_re type_color markup
      end else begin
        Str.replace_first type_color_re type_color_sel markup
      end in
      model#set ~row ~column:col_markup new_markup;
    in
    ignore (view#selection#connect#changed ~callback:begin fun () ->
      match view#selection#get_selected_rows with
        | path :: _ ->
          Gaux.may last_selected_path ~f:(replace_color_in_markup model true);
          replace_color_in_markup model false path;
          last_selected_path <- Some path;
        | _ -> ()
    end);
    (** Tooltips *)
    view#misc#set_has_tooltip true;
    ignore (view#misc#connect#query_tooltip ~callback:self#create_tooltip);
    (** Events *)
    signal_selection_changed <- Some (view#selection#connect#after#changed ~callback:begin fun () ->
      self#select_element();
      match view#selection#get_selected_rows with
        | path :: _ ->
          let row = model#get_iter path in
          self#force_lazy row;
          selected_path <- Some (self#get_id_path row)
        | _ -> ()
    end);
    ignore (view#connect#after#row_activated ~callback:begin fun _ _ ->
      self#select_element();
      page#view#misc#grab_focus();
    end);
    ignore (view#connect#row_expanded ~callback:begin fun row path ->
      self#add_table_expanded_by_user (self#get_id_path row) path
    end);
    ignore (view#connect#row_collapsed ~callback:begin fun row _ ->
      table_expanded_by_user <- List.remove_assoc (self#get_id_path row) table_expanded_by_user;
    end);
    ignore (view#misc#connect#realize ~callback:begin fun () ->
      let show = Preferences.preferences#get.Preferences.pref_outline_show_types in
      if show <> button_show_types#active then button_show_types#clicked()
    end);
    (** Buttons *)
    ignore (button_refresh#connect#clicked ~callback:self#load);
    ignore (button_show_types#connect#toggled ~callback:begin fun () ->
      model#foreach begin fun path row ->
        let name = model#get ~row ~column:col_name in
        try
          let info = Hashtbl.find table_info path in
          let markup = self#create_markup ?kind:info.kind name info.typ in
          model#set ~row ~column:col_markup markup;
          false
        with Not_found -> false
      end;
      Preferences.preferences#get.Preferences.pref_outline_show_types <- button_show_types#active;
      (*Preferences.save();*)
    end);

  method private force_lazy row =
    begin
      try List.iter (fun f -> f()) (List.rev (model#get ~row ~column:col_lazy));
      with Failure _ -> ()
    end;
    model#set ~row ~column:col_lazy []

  method view = view

  method select ?(align : float option) (mark : Gtk.text_mark) = ()

  method select_element () =
    match view#selection#get_selected_rows with
      | [] -> ()
      | path :: _ ->
        try
          let info = Hashtbl.find table_info path in
          Gaux.may info.location ~f:begin fun loc ->
            match info.mark with
              | Some mark when not (GtkText.Mark.get_deleted mark) ->
                let start = buffer#get_iter_at_mark (`MARK mark) in
                let _, (c, d) = linechar_of_loc loc in
                let _, ts = timestamp in
                if ts = (Unix.stat filename).Unix.st_mtime then begin (* .tmp/filename *)
                  let stop = ref start in
                  while (!stop#line < c || !stop#line_index < d) && not (!stop#equal buffer#end_iter) do
                    stop := !stop#forward_char
                  done;
                  buffer#select_range start !stop;
                end else (buffer#place_cursor ~where:start);
                page#view#scroll_lazy start;
              | _ -> ()
          end
        with Not_found -> ()

  method load () =
    let source = page#get_filename in
    match Project.tmp_of_abs editor#project source with
      | Some (tmp, relname) ->
        Miscellanea.crono  self#load' (tmp // relname);
      | _ -> ()

  method private load' file =
    filename <- file;
    let ext = if filename ^^ ".ml" then Some ".cmt" else if filename ^^ ".mli" then Some ".cmti" else None in
    match ext with
      | Some ext ->
        let filename_cmt = (Filename.chop_extension filename) ^ ext in
        timestamp <- file, (Unix.stat filename).Unix.st_mtime;
        let cmi, cmt = Cmt_format.read filename_cmt in
        (* Delete previous marks in the buffer and clear the model and other conatiners *)
        GtkThread2.sync begin fun () ->
          buffer#block_signal_handlers ();
          Hashtbl.iter (fun _ info -> match info.mark with Some mark -> buffer#delete_mark (`MARK mark) | _ -> ()) table_info;
          buffer#unblock_signal_handlers ();
        end ();
        model#clear();
        table_expanded_by_default <- [];
        table_collapsed_by_default <- [];
        Hashtbl.clear table_info;
        (* Parse .cmt file *)
        Gaux.may cmt ~f:(fun cmt -> self#parse cmt.cmt_annots);
        (*  *)
        List.iter view#expand_row table_expanded_by_default;
        (* Select the same row that was selected in the previous tree *)
        Gaux.may selected_path ~f:begin fun sid ->
          GtkThread2.async model#foreach begin fun path row ->
            let id = self#get_id_path row in
            if id = sid then begin
              Gaux.may signal_selection_changed ~f:view#selection#misc#handler_block;
              view#selection#select_path path;
              Gaux.may signal_selection_changed ~f:view#selection#misc#handler_unblock;
              true
            end else false
          end
        end
      | _ -> ()

  method private parse = function
    | Implementation impl -> List.iter self#append_struct_item impl.str_items
    | Partial_implementation part_impl ->
      let row = model#append () in
      model#set ~row ~column:col_markup "Partial_implementation"
    | Interface sign ->
      List.iter self#append_sig_item sign.sig_items;
    | Partial_interface part_intf ->
      let row = model#append () in
      model#set ~row ~column:col_markup "Partial_iterface"
    | Packed _ ->
      let row = model#append () in
      model#set ~row ~column:col_markup "Packed"

  method private create_markup ?kind name typ =
    let markup_name =
      match kind with
        | Some Class | Some Class_virtual | Some Class_type | Some Module | Some Module_functor ->
          "<b>" ^ (Glib.Markup.escape_text name) ^ "</b>"
        | Some Initializer | Some Class_let_bindings | Some Method_inherited -> "<i>" ^ (Glib.Markup.escape_text name) ^ "</i>"
        | _ -> Glib.Markup.escape_text name
    in
    let typ_utf8 = Glib.Convert.convert_with_fallback ~fallback:"" ~from_codeset:Oe_config.ocaml_codeset ~to_codeset:"UTF-8" typ in
    if button_show_types#active && typ <> "" then String.concat "" [
      markup_name; span_type_color;
      (Print_type.markup2 (Miscellanea.replace_all ~regexp:true ["\n", ""; " +", " "] typ_utf8));
      "</span>"
    ] else markup_name

  method private create_tooltip ~x ~y ~kbd tooltip =
    try
      begin
        match GtkTree.TreeView.Tooltip.get_context view#as_tree_view ~x ~y ~kbd with
          | (x, y, Some (_, _, row)) ->
            begin
              match view#get_path_at_pos ~x ~y with
                | Some (tpath, _, _, _) ->
                  begin
                    let info = Hashtbl.find table_info tpath in
                    if info.typ <> "" then begin
                      let name = model#get ~row ~column:col_name in
                      let markup = sprintf "<span color='darkblue'>%s</span> :\n%s"
                        (Glib.Markup.escape_text name) (Print_type.markup2 info.typ) in
                      (*GtkBase.Tooltip.set_markup tooltip markup;*)
                      (*GtkBase.Tooltip.set_tip_area tooltip (view#get_cell_area ~path:tpath (*~col:vc*) ());*)
                      !label_tooltip#set_label markup;
                      GtkTree.TreeView.Tooltip.set_row view#as_tree_view tooltip tpath;
                      Gaux.may !label_tooltip#misc#parent ~f:(fun _ -> label_tooltip := GMisc.label ~markup ());
                      GtkBase.Tooltip.set_custom tooltip !label_tooltip#as_widget;
                      true
                    end else false
                  end;
                | _ -> false
            end
          | _ -> false
      end
    with Not_found | Gpointer.Null -> false

  method private append ?parent ?kind ?loc ?loc_body name typ =
    let markup = self#create_markup ?kind name typ in
    GtkThread2.sync begin fun () ->
      let row = model#append ?parent () in
      let path = model#get_path row in
      model#set ~row ~column:col_name name;
      model#set ~row ~column:col_markup markup;
      let info = {
        typ      = typ;
        kind     = kind;
        location = loc;
        mark     = None;
      } in
      Gaux.may kind ~f:(fun k -> Gaux.may (pixbuf_of_kind k) ~f:(model#set ~row ~column:col_icon));
      Gaux.may loc ~f:begin fun loc ->
        let (line, start), _ = linechar_of_loc loc in
        if line <= buffer#end_iter#line then begin
          let iter : GText.iter = buffer#get_iter (`LINE line) in
          (*let iter = iter#set_line_index 0 in*)
          let iter = iter#forward_chars start in
          if iter#line = line then begin
            buffer#block_signal_handlers ();
            info.mark <- Some (buffer#create_mark ?left_gravity:None iter);
            buffer#unblock_signal_handlers ()
          end
        end
      end;
      Hashtbl.add table_info path info;
      row
    end ()

  method private append_struct_item ?parent item =
    match item.str_desc with
      | Tstr_eval expr ->
        let loc = {item.str_loc with loc_end = item.str_loc.loc_start} in
        ignore (self#append ?parent ~loc ~loc_body:expr.exp_loc "_" "")
      | Tstr_value (_, pe) ->
        List.iter (fun (pat, _) -> ignore (self#append_pattern ?parent pat)) pe
      | Tstr_class classes -> List.iter (self#append_class ?parent) classes
      | Tstr_class_type classes -> List.iter (fun (_, loc, decl) -> self#append_class_type ?parent ~loc decl) classes
      | Tstr_type decls -> List.iter (self#append_type ?parent) decls
      | Tstr_exception (_, loc, decl) ->
        let exn_params = self#string_of_core_types decl.exn_params in
        ignore (self#append ?parent ~kind:Exception ~loc:loc.loc loc.txt exn_params)
      | Tstr_module (_, loc, module_expr) ->
        let kind =
          match module_expr.mod_desc with
            | Tmod_functor _ -> Module_functor
            | _ -> Module
        in
        let parent_mod = self#append ?parent ~kind ~loc:loc.loc loc.txt "" in
        let f () = self#append_module ~parent:parent_mod module_expr.mod_desc in
        begin
          match parent with
            | Some _ -> model#set ~row:parent_mod ~column:col_lazy [f];
            | _ -> f()
        end;
        table_expanded_by_default <- (model#get_path parent_mod) :: table_expanded_by_default;
      | Tstr_modtype (_, loc, mt) ->
        let parent = self#append ?parent ~kind:Module_type ~loc:loc.loc loc.txt "" in
        model#set ~row:parent ~column:col_lazy [fun () -> self#append_module_type ~parent mt.mty_desc];
      | Tstr_recmodule _ -> ()
      | Tstr_include _ | Tstr_open _ | Tstr_exn_rebind _ | Tstr_primitive _ -> ()

  method private append_sig_item ?parent item =
    match item.sig_desc with
      | Tsig_value (_, loc, desc) ->
        Odoc_info.reset_type_names();
        let typ = string_of_type_expr desc.val_desc.ctyp_type in
        ignore (self#append ?parent ~kind:Function ~loc:loc.loc ~loc_body:desc.val_desc.ctyp_loc loc.txt typ);
      | Tsig_type decls -> List.iter (self#append_type ?parent) decls
      | Tsig_exception (_, loc, decl) ->
        let exn_params = self#string_of_core_types decl.exn_params in
        ignore (self#append ?parent ~kind:Exception ~loc:loc.loc loc.txt exn_params)
      | Tsig_module (_, loc, mty) ->
        let kind =
          match mty.mty_desc with
            | Tmty_functor _ -> Module_functor
            | _ -> Module
        in
        let parent_mod = self#append ?parent ~kind ~loc:loc.loc loc.txt "" in
        let f () = self#append_module_type ~parent:parent_mod mty.mty_desc in
        begin
          match parent with
            | Some _ -> model#set ~row:parent_mod ~column:col_lazy [f];
            | _ -> f()
        end;
        table_expanded_by_default <- (model#get_path parent_mod) :: table_expanded_by_default;
      | Tsig_recmodule _ -> ignore (self#append ?parent "Tsig_recmodule" "")
      | Tsig_modtype (_, loc, modtype_decl) ->
        let parent = self#append ?parent ~kind:Module_type ~loc:loc.loc loc.txt "" in
        let f () =
          match modtype_decl with
            | Tmodtype_abstract -> ()
            | Tmodtype_manifest mt -> self#append_module_type ~parent mt.mty_desc
        in
        model#set ~row:parent ~column:col_lazy [f];
      | Tsig_open _ -> ignore (self#append ?parent "Tsig_open" "")
      | Tsig_include _ -> ignore (self#append ?parent "Tsig_include" "")
      | Tsig_class classes ->
        List.iter (fun clty -> self#append_class_type ?parent ~loc:clty.ci_id_name clty) classes;
      | Tsig_class_type decls ->
        List.iter (fun info -> self#append_class_type ?parent ~loc:info.ci_id_name info) decls;

  method private append_module ?parent mod_desc =
    match mod_desc with
      | Tmod_functor (_, floc, mtype, mexpr) ->
        self#append_module ?parent mexpr.mod_desc
      | Tmod_structure str ->
        List.iter (self#append_struct_item ?parent) str.str_items
      | Tmod_ident _ -> ignore (self#append ?parent "Tmod_ident" "")
      | Tmod_apply _ -> ()
      | Tmod_constraint _ -> ignore (self#append ?parent "Tmod_constraint" "")
      | Tmod_unpack _ -> ignore (self#append ?parent "Tmod_unpack" "")

  method private append_module_type ?parent mod_desc =
    match mod_desc with
      | Tmty_functor (_, floc, mtype, mexpr) ->
        self#append_module_type ?parent mexpr.mty_desc
      | Tmty_ident (path, loc) -> ignore (self#append ?parent ~loc:loc.loc "Tmty_ident" "")
      | Tmty_signature sign ->
        List.iter (self#append_sig_item ?parent) sign.sig_items
      | Tmty_with _ -> ignore (self#append ?parent "Tmty_with" "")
      | Tmty_typeof _ -> ignore (self#append ?parent "Tmty_typeof" "")

  method private append_type ?parent (_, loc, decl) =
    let kind =
      match decl.typ_kind with
        | Ttype_abstract -> Type_abstract
        | Ttype_variant _ -> Type_variant
        | Ttype_record _ -> Type_record
    in
    let typ =
      match decl.typ_kind with
        | Ttype_abstract -> self#string_of_type_abstract decl
        | Ttype_variant decls -> self#string_of_type_variant decls
        | Ttype_record decls -> self#string_of_type_record decls
    in
    ignore (self#append ?parent ~kind ~loc:loc.loc loc.txt typ)

  method private append_pattern ?parent pat =
    match pat.pat_desc with
      | Tpat_var (_, loc) ->
        let kind = if is_function pat.pat_type then Function else Simple in
        Odoc_info.reset_type_names();
        Some (self#append ?parent ~kind ~loc:loc.loc loc.txt (string_of_type_expr pat.pat_type))
      | Tpat_tuple pats ->
        List.iter (fun pat -> ignore (self#append_pattern ?parent pat)) pats;
        None
      | (*Tpat_construct _ | Tpat_any | Tpat_alias _ | Tpat_constant _
      | Tpat_variant _ | Tpat_record _ | Tpat_array _ | Tpat_or _
      | Tpat_lazy*) _ -> None

  method private append_class ?parent (infos, _, _) =
    let kind = if infos.ci_virt = Asttypes.Virtual then Class_virtual else Class in
    let parent = self#append ~kind ?parent ~loc:infos.ci_id_name.loc infos.ci_id_name.txt "" in
    let let_bindings_parent = self#append ~kind:Class_let_bindings ~loc:infos.ci_id_name.loc ~parent "let-bindings" "" in
    let count_meth = ref 0 in
    let id_path = self#get_id_path let_bindings_parent in
    let expand_lets = List_opt.assoc id_path table_expanded_by_user <> None in
    ignore (self#append_class_item ~let_bindings_parent ~expand_lets ~count_meth ~parent infos.ci_expr.cl_desc);
    (*let not_has_childs =
      try
        model#iter_n_children (Some let_bindings_parent) = 0 &&
        (model#get ~row:let_bindings_parent ~column:col_lazy) = []
      with Failure _ -> true
    in
    (* DO NOT REMOVE ROWS FROM THE MODEL TO NOT ALTER PATHS IN INDEXES. *)
    if not_has_childs then (ignore (model#remove let_bindings_parent))
    else *)if not expand_lets then begin
      let path = model#get_path let_bindings_parent in
      self#add_table_collapsed_by_default id_path path;
    end;
    if !count_meth > 0 then begin
      table_expanded_by_default <- (model#get_path parent) :: table_expanded_by_default;
    end

  method private append_class_item ?let_bindings_parent ?(expand_lets=false) ?count_meth ?parent = function
    | Tcl_structure str ->
      List.map begin fun fi ->
        match fi.cf_desc with
          | Tcf_inher (_, cl_expr, id, inherited_fields, inherited_methods) ->
            let parent = self#append_class_item ?let_bindings_parent ~expand_lets ?count_meth ?parent cl_expr.cl_desc in
            Gaux.may parent ~f:begin fun parent ->
              let f () = List.iter (fun (x, _) -> ignore (self#append ~kind:Method_inherited ~parent x "")) inherited_methods in
              let id_path = self#get_id_path parent in
              let expand_inher = List_opt.assoc id_path table_expanded_by_user <> None in
              if expand_inher then begin
                f();
                table_expanded_by_default <- (model#get_path parent) :: table_expanded_by_default;
              end else begin
                self#add_table_collapsed_by_default (self#get_id_path parent) (model#get_path parent);
                model#set ~row:parent ~column:col_lazy [f];
              end
            end;
            parent
          | Tcf_init _ ->
            let loc = {fi.cf_loc with loc_end = fi.cf_loc.loc_start} in
            Some (self#append ~kind:Initializer ~loc ?parent "initializer" "");
          | Tcf_val (_, loc, mutable_flag, _, kind, _) ->
            let typ, kind = match kind with
              | Tcfk_virtual ct when mutable_flag = Mutable ->
                string_of_type_expr ct.ctyp_type, Attribute_mutable_virtual
              | Tcfk_virtual ct  ->
                string_of_type_expr ct.ctyp_type, Attribute_virtual
              | Tcfk_concrete te when mutable_flag = Mutable ->
                string_of_type_expr te.exp_type, Attribute_mutable
              | Tcfk_concrete te ->
                string_of_type_expr te.exp_type, Attribute
            in
            Some (self#append ?parent ~kind ~loc:loc.loc loc.txt typ);
          | Tcf_meth (_, loc, private_flag, kind, _) ->
            let kind, typ, loc_body = match kind with
              | Tcfk_virtual ct when private_flag = Private ->
                Method_private_virtual, string_of_type_expr ct.ctyp_type, ct.ctyp_loc
              | Tcfk_virtual ct ->
                Method_virtual, string_of_type_expr ct.ctyp_type, ct.ctyp_loc
              | Tcfk_concrete te when private_flag = Private ->
                Method_private, string_of_type_expr te.exp_type, te.exp_loc
              | Tcfk_concrete te ->
                Method, string_of_type_expr te.exp_type, te.exp_loc
            in
            Gaux.may count_meth ~f:incr;
            Some (self#append ?parent ~kind ~loc:loc.loc ~loc_body:loc_body loc.txt typ);
          | Tcf_constr (ct1, _) -> Some (self#append ?parent ~loc:ct1.ctyp_loc (sprintf "Tcf_constr") "");
      end str.cstr_fields;
      parent
    | Tcl_fun (_, _, _, cl_expr, _) ->
      self#append_class_item ?let_bindings_parent ~expand_lets ?count_meth ?parent cl_expr.cl_desc;
    | Tcl_ident (_, lid, _) ->
      Some (self#append ?parent ~kind:Class_inherit ~loc:lid.loc (String.concat "." (Longident.flatten lid.txt)) "");
    | Tcl_apply (cl_expr, _) ->
      self#append_class_item ?let_bindings_parent ~expand_lets ?count_meth ?parent cl_expr.cl_desc;
    | Tcl_let (_, lets, _, desc) ->
      Gaux.may let_bindings_parent ~f:begin fun row ->
        let f () =
          List.iteri begin fun i (pat, expr) ->
            ignore (self#append_pattern ~parent:row pat);
            if i = 0 && expand_lets then begin
              let path = model#get_path row in
              table_expanded_by_default <- path ::  table_expanded_by_default;
              self#add_table_expanded_by_user (self#get_id_path row) path
            end
          end lets
        in
        if expand_lets then f() else begin
          let prev = try model#get ~row ~column:col_lazy with Failure _ -> [] in
          model#set ~row ~column:col_lazy (f :: prev)
        end
      end;
      self#append_class_item ?let_bindings_parent ~expand_lets ?count_meth ?parent desc.cl_desc;
    | Tcl_constraint (cl_expr, _, _, _, _) ->
      self#append_class_item ?let_bindings_parent ~expand_lets ?count_meth ?parent cl_expr.cl_desc;

  method private append_class_type ?parent ~loc infos =
    let parent = self#append ~kind:Class_type ?parent ~loc:loc.loc loc.txt "" in
    let count_meth = ref 0 in
    ignore (self#append_class_type_item ~parent ~count_meth infos.ci_expr.cltyp_desc);
    if !count_meth > 0 then begin
      table_expanded_by_default <- (model#get_path parent) :: table_expanded_by_default;
    end

  method private append_class_type_item ?parent ?count_meth = function
    | Tcty_constr _ -> ignore (self#append ?parent (sprintf "Tcty_constr") "")
    | Tcty_signature sign ->
      List.iter begin fun field ->
        match field.ctf_desc with
          | Tctf_inher _ -> ignore (self#append ?parent (sprintf "Tctf_inher") "")
          | Tctf_val _ -> ignore (self#append ?parent (sprintf "Tctf_val") "")
          | Tctf_virt _ -> ignore (self#append ?parent (sprintf "Tctf_virt") "")
          | Tctf_meth (id, private_flag, ct) ->
            Gaux.may count_meth ~f:incr;
            let kind = match private_flag with Private -> Method_private | _ -> Method in
            ignore (self#append ?parent ~kind ~loc:field.ctf_loc id (string_of_type_expr ct.ctyp_type))
          | Tctf_cstr _ -> ignore (self#append ?parent (sprintf "Tctf_cstr") "")
      end (List.rev sign.csig_fields)
    | Tcty_fun (_, _, class_type) -> ignore (self#append_class_type_item ?parent class_type.cltyp_desc)

  method private string_of_type_abstract decl =
    match decl.typ_manifest with
      | Some ct -> Odoc_info.string_of_type_expr ct.ctyp_type
      | _ -> ""

  method private string_of_type_record decls =
    Odoc_info.reset_type_names();
    String.concat "" ["{ \n  ";
      String.concat ";\n  " (List.map begin fun (_, loc, _is_mutable, ct, _) ->
        loc.txt ^ ": " ^ string_of_type_expr ct.ctyp_type
      end decls);
      " \n}"]

  method private string_of_type_variant decls =
    Odoc_info.reset_type_names();
    "   " ^ (String.concat "\n | " (List.map begin fun (_, loc, types, _) ->
      loc.txt ^
        let ts = self#string_of_core_types types in
        if ts = "" then "" else (" of " ^ ts)
    end decls))

  method private string_of_core_types ctl =
    String.concat " * " (List.map (fun ct -> string_of_type_expr ct.ctyp_type) ctl)

  method private get_id_path row =
    let rec loop row id =
      match model#iter_parent row with
        | Some parent ->
          loop parent ((model#get ~row:parent ~column:col_name) ^ "." ^ id)
        | _ -> id
    in
    loop row (model#get ~row ~column:col_name)

  method private add_table_expanded_by_user id path =
    table_expanded_by_user <- (id, path) :: (List.remove_assoc id table_expanded_by_user)

  method private add_table_collapsed_by_default id path =
    table_collapsed_by_default <- (id, path) :: (List.remove_assoc id table_collapsed_by_default)

  method connect = new signals ~changed
end

and changed () = object inherit [string * bool] signal () end
and signals ~changed =
object
  inherit ml_signals [changed#disconnect]
  method changed = changed#connect ~after
end

let create = new widget

let window ~editor ~page () =
  let window = GWindow.window ~position:`CENTER ~show:false () in
  let vbox = GPack.vbox ~packing:window#add () in
  let widget = create ~editor ~page ~packing:vbox#add () in
  ignore (window#event#connect#key_press ~callback:begin fun ev ->
    if GdkEvent.Key.keyval ev = GdkKeysyms._Escape then (window#destroy (); true)
    else false
  end);
  window#present();
  widget, window;;
