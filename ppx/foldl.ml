open Ppx_core
open Printf
open Ast_helper
open GtHelpers
open Ppx_core.Ast_builder.Default

let make_dest_param_names ?(loc=Location.none) ps =
  map_type_param_names ps ~f:(sprintf "%s_2")

let hack_params ?(loc=Location.none) ps =
  let param_names = map_type_param_names ps ~f:id in
  let rez_names = make_dest_param_names ~loc ps in
  let name_migrations = List.zip_exn param_names rez_names in
  let assoc s =
    try List.Assoc.find_exn ~equal:String.equal name_migrations s
    with Not_found ->
      raise_errorf "can't find new typ for param `%s" s
  in
  let blownup_params =
    List.concat_map param_names
      ~f:(fun s1 ->
           [Typ.var ~loc s1; Typ.var ~loc @@ assoc s1 ]
         )
  in
  (param_names, rez_names, assoc, blownup_params)

open Plugin

let g = object(self: 'self)
  inherit ['self] Plugin.generator

  method plugin_name = "foldl"

  method default_inh = let loc = Location.none in [%type: 'syn]
  method default_syn tdecl =
    let loc = tdecl.ptype_loc in
    [%type: 'syn]

  method plugin_class_params tdecl =
    List.map ~f:fst tdecl.ptype_params
    (* let param_names,_,find_param,blownup_params = hack_params tdecl.ptype_params in
     * blownup_params *)

  method make_class ~loc tdecl ~is_rec mutal_names =
    let cur_name = self#cur_name tdecl in
    let param_names,rez_names,find_param,blownup_params = hack_params tdecl.ptype_params in

    let ans ?(is_poly=false) fields =
      (* let syn_of_param ~loc _ = self#default_syn tdecl in *)
      self#wrap_class_definition ~loc mutal_names tdecl ~is_poly fields
        ~inh_params:(let inh_params = prepare_param_triples ~loc
                         ~inh:(fun ~loc n -> self#default_inh
                                  (* Typ.var ~loc ("i"^n) *) )
                         ~syn:(fun ~loc n -> self#default_syn tdecl
                                  (* Typ.var ~loc ("s"^n) *) )
                         ~default_syn:(self#default_syn tdecl)
                         ~default_inh:(self#default_syn tdecl)
                         (List.map ~f:fst tdecl.ptype_params)
                     in
                     if is_poly
                     then inh_params @ [[%type: 'polyvar_extra]]
                     else inh_params
                    )
        ~default_syn:(self#default_syn tdecl)
    in

  let is_self_rec t = is_rec &&
    match t.ptyp_desc with
    | Ptyp_var _ -> false
    | Ptyp_constr ({txt=Lident s}, params)
      when String.equal s cur_name &&
           List.length params = List.length tdecl.ptype_params &&
           List.for_all2_exn params tdecl.ptype_params
             ~f:(fun a (b,_) -> 0=compare_core_type a b)
      -> is_rec
    | _ -> false
    in
  self#got_typedecl tdecl is_self_rec (fun ~is_poly -> ans ~is_poly)

  method got_constr ~loc tdecl is_self_rec do_typ cid cparams k =
    (* let _param_names,_rez_names,find_param,_blownup_params =
     *   hack_params tdecl.ptype_params
     * in *)

    let ans args =
      [ (* let params = List.concat_map cparams ~f:(fun t ->
         *     [t; map_core_type t ~onvar:(fun s -> Typ.var ~loc (find_param s))]
         *   ) in *)
        let params  = cparams in
        Cf.inherit_ ~loc @@ Cl.apply
          (Cl.constr (Located.map (map_longident
                                     ~f:(sprintf "%s_%s" self#plugin_name)) cid)
             params)
          (nolabelize args)
      ]
    in
    (* for typ aliases we can cheat because first argument of constructor of type
       on rhs is self transformer function *)
    (* let self_arg = do_typ typ in *)
    k @@ ans @@
    (Exp.sprintf ~loc "%s" self_arg_name) ::
    (List.concat_map cparams ~f:(self#do_typ ~loc is_self_rec))


  method got_polyvar ~loc tdecl do_typ is_self_rec rows k =
    let _param_names,_rez_names,_find_param,blownup_params =
      hack_params tdecl.ptype_params
    in
    k @@
    List.map rows ~f:(function
        | Rinherit typ ->
          with_constr_typ typ
            ~fail:(fun () -> failwith "type is not a constructor")
            ~ok:(fun cid params ->
                let args = List.concat_map params ~f:(self#do_typ ~loc is_self_rec) in
                let inh_params = blownup_params @ [[%type: 'polyvar_extra]] in
                Cf.inherit_ ~loc @@ Cl.apply
                  (Cl.constr
                     ({cid with txt = map_longident cid.txt ~f:((^)"gmap_")})
                     inh_params
                  )
                  (nolabelize ([%expr _fself]::args))
              )
        | Rtag (constr_name,_,_,ts) ->
          let names = make_new_names (List.length ts) in

          Cf.method_concrete ~loc ("c_" ^ constr_name)
            [%expr fun () -> [%e
              Exp.fun_list ~args:(List.map names ~f:(Pat.sprintf "%s")) @@
              let ctuple =
                if List.length ts = 0
                then None
                else Some (Exp.tuple ~loc @@
                           List.concat_map (List.zip_exn names ts)
                             ~f:(fun (name, typ) -> self#do_typ ~loc is_self_rec ~with_arg:name typ)
                          )
              in
              Exp.variant ~loc constr_name ctuple
            ]]

      )

  method do_typ ~loc ?with_arg is_self_rec t =
    (* TODO: if with_arg we need to apply result to arg else return result as it is *)
    (* TODO: we really should do this *)
    let app_arg e =
      match with_arg with
      | Some ""
      | None -> [e]
      | Some x -> [Exp.apply_nolabeled ~loc e [ [%expr inh]; Exp.ident ~loc x] ]
    in
    if is_self_rec t then app_arg [%expr _fself ]
    else
      match t with
      | [%type: int]
      | [%type: string] -> app_arg [%expr fun inh _ -> inh ]
      | t -> match t.ptyp_desc with
        | Ptyp_var name ->
          app_arg Exp.(sprintf "f%s" name)
        | Ptyp_tuple params ->
          app_arg @@
          Exp.apply
            (Exp.sprintf "%s_tuple%d" self#plugin_name (List.length params))
            (List.concat_map params ~f:(self#do_typ ~loc is_self_rec) |> nolabelize)
        | Ptyp_constr (_,_) when is_self_rec t ->
          (* This can be moved to the base class too *)
          app_arg [%expr _fself]
        | Ptyp_constr ({txt}, params) ->
            (* There we are only interested in the arguments that are type variables*)
          app_arg @@
          Exp.apply
            (Exp.ident_of_long @@ mknoloc @@
             map_longident ~f:(sprintf "%s_%s" self#plugin_name) txt)
            (List.concat_map params ~f:((self#do_typ ~loc is_self_rec)) |> nolabelize)
        | Ptyp_variant (rows, _, maybe_labels) -> begin
            let oninherit typs cident varname =
              Exp.apply_nolabeled ~loc
                Exp.(ident_of_long ~loc @@ mknoloc @@
                     map_longident cident
                       ~f:(Printf.sprintf "%s_%s" self#plugin_name))
                ((List.concat_map typs ~f:(self#do_typ ~loc is_self_rec)) @
                 [[%expr ()]; Exp.ident ~loc varname])
            in
            let onrow lab = function
            | [] -> Exp.variant ~loc lab None
            | args ->
                Exp.variant ~loc lab @@ Option.some @@ Exp.tuple ~loc @@
                List.concat_map args ~f:(fun (name,t) ->
                  self#do_typ ~loc is_self_rec ~with_arg:name t)
            in
            match with_arg with
            | Some s ->
              prepare_patt_match_poly ~loc
                (Exp.sprintf ~loc "%s" s) rows maybe_labels
                ~onrow
                ~onlabel:(fun _ _ -> [%expr 1])
                ~oninherit
                :: []
            | None ->
              let k e = [%expr fun () foo -> [%e e]] :: [] in
              k @@ prepare_patt_match_poly ~loc
                (Exp.sprintf ~loc "foo") rows maybe_labels
                ~onrow
                ~onlabel:(fun _ _ -> [%expr 1])
                ~oninherit
          end
        | _ -> failwith "Finish it!"


  method on_tuple_constr tdecl is_self_rec cd ts =
    let loc = tdecl.ptype_loc in
    let names = make_new_names (List.length ts) in
    let constr_name = cd.pcd_name.txt in
    Cf.method_concrete ~loc ("c_"^cd.pcd_name.txt)
      [%expr fun () -> [%e
        Exp.fun_list ~args:(List.map names ~f:(Pat.sprintf "%s")) @@
        let ctuple =
          if List.length ts = 0
          then None
          else Some (Exp.tuple ~loc @@
                     List.concat_map (List.zip_exn names ts)
                       ~f:(fun (name, typ) -> self#do_typ ~loc ~with_arg:name is_self_rec typ)
                    )
        in
        Exp.construct ~loc (Located.mk ~loc (Lident constr_name)) ctuple
      ]]

end