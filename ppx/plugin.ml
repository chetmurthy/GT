open Base
open Ppxlib
open Printf
open Asttypes
open Parsetree
open Ast_helper
open Location
open GtHelpers
open Ppxlib.Ast_builder.Default

let self_arg_name = "fself"
let construct_extra_param ~loc = [%type: 'extra]

class virtual ['self] generator initial_args = object(self: 'self)
  inherit Plugin_intf.t

  (* parse arguments like { _1=<expr>; ...; _N=<expr>; ...} *)
  val reinterpreted_args =
    let check_name s =
      try Caml.Scanf.sscanf s "_%d" (fun n -> Some n)
      with Caml.Scanf.Scan_failure _ ->
        (* printf "can't parse it\n%!"; *) None
    in
    let ans =
      List.fold_left initial_args ~init:[]
        ~f:(fun acc (lident,expr) ->
            match lident with
            | Lident s -> Option.value_map (check_name s) ~default:acc
                            ~f:(fun n -> (n,expr) :: acc)
            | _ -> acc
          )
    in
    (* printf "Total args found for plugin : %d\n%!"  (List.length ans); *)
    ans

  method show_args =
    List.iter reinterpreted_args ~f:(fun (k,e) ->
        Format.printf "%d -> %a\n%!" k Pprintast.expression e
      )

  method extra_param_stub ~loc = construct_extra_param ~loc

  method extra_class_sig_members _ = []
  method extra_class_str_members _ = []
  method cur_name tdecl = tdecl.ptype_name.txt

  (* preparing class of transformation for [tdecl] *)
  method make_class ~loc tdecl ~is_rec mutal_names =
    let cur_name = self#cur_name tdecl in
    let k fields =
      let inh_params =
        let inh_params = prepare_param_triples ~loc
            ~inh:(fun ~loc _ -> self#default_inh)
            ~syn:self#syn_of_param
            ~default_syn:(self#default_syn tdecl)
            tdecl.ptype_params
        in
        inh_params @ [self#extra_param_stub ~loc]
      in
      self#wrap_class_definition ~loc mutal_names tdecl ~inh_params
        ((self#extra_class_str_members tdecl) @ fields)
    in

    let is_self_rec t =
      is_rec &&
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
    self#got_typedecl tdecl ~is_self_rec ~mutal_names k

  method extra_class_lets tdecl k =
    k

  method wrap_class_definition ~loc ~inh_params mutal_names tdecl fields =
    let cur_name = self#cur_name tdecl in
    (* inherit class_t and prepare to put other members *)

    Str.class_single ~loc
      ~params:(invariantize @@ self#plugin_class_params tdecl )
      ~name:(sprintf "%s_%s%s" self#plugin_name cur_name
               (match mutal_names with [] -> "" | _ -> "_stub") )
      ~virt:Concrete
      ~wrap:(self#extra_class_lets tdecl @@ fun body ->
        (* constructor arguments are *)
        let names =
          List.map mutal_names
            ~f:(Pat.sprintf ~loc "%s_%s" self#plugin_name) @
          [Pat.var ~loc self_arg_name] @
          map_type_param_names tdecl.ptype_params ~f:(Pat.sprintf ~loc "f%s")
        in
        Cl.fun_list names body
      )
      @@
      [ Cf.inherit_ (Cl.constr ~loc (Lident ("class_"^cur_name)) inh_params)
      ] @ fields

  (* shortened class only used for mutally recursive declarations *)
  method make_shortend_class ~loc ~is_rec mutal_names tdecls =
    List.map tdecls ~f:(fun tdecl ->
      let mutal_names = List.filter mutal_names
          ~f:(String.(<>) tdecl.ptype_name.txt) in
      let class_name = sprintf "%s_%s" self#plugin_name tdecl.ptype_name.txt in
      let stub_name = class_name ^ "_stub" in
      (* maybe it should be called proto *)
      let mut_funcs = List.map ~f:(sprintf "%s_%s" self#plugin_name) mutal_names in
      let real_args = "fself" :: (List.map ~f:((^)"f") @@ make_new_names (List.length tdecl.ptype_params)) in
      let new_params = self#plugin_class_params tdecl in
      Str.single_class ~loc ~name:class_name
        ~wrap:(Cl.fun_list @@ List.map ~f:(Pat.sprintf ~loc "%s") @@ real_args)
        ~params:(invariantize new_params)
        [ Cf.inherit_ ~loc @@ Cl.apply
            (Cl.constr ~loc (Lident stub_name) new_params)
            (nolabelize @@
             List.map ~f:(Exp.sprintf ~loc "%s") (mut_funcs@real_args) )
        ]
    )

  (* signature for a plugin class *)
  method make_class_sig ~loc tdecl ~is_rec (mutal_decls: type_declaration list) =
    let k fields =
      [ Sig.class_ ~loc
          ~params:(invariantize @@ self#plugin_class_params tdecl)
          ~name:(sprintf "%s_%s%s" self#plugin_name (self#cur_name tdecl)
                   (match mutal_decls with [] -> "" | _ -> "_stub") )
          ~virt:Concrete
          ~wrap:(fun init ->
              let from_mutals =
                List.map mutal_decls
                  ~f:(fun tdecl ->
                      self#chain_inh_syn ~loc
                          ~syn_t:[%type: int]
                          (using_type ~typename:tdecl.ptype_name.txt tdecl)
                    )
              in
              let for_self = self#make_typ_of_self_trf ~loc tdecl in
              let funcs_for_args = map_type_param_names tdecl.ptype_params
                  ~f:(fun name ->
                      self#make_RHS_typ_of_transformation
                        ~syn_t:(self#syn_of_param ~loc name)
                        ~subj_t:(Typ.var ~loc name)
                        tdecl
                    )
              in
              List.fold_right ~init (from_mutals@[for_self]@funcs_for_args)
                ~f:(Cty.arrow ~loc Nolabel)
            )
          ((self#extra_class_sig_members tdecl) @ fields)
      ]
    in
    visit_typedecl ~loc tdecl
    ~onmanifest:(fun typ ->
        let rec helper typ =
          match typ.ptyp_desc with
          | Ptyp_alias (t, aname) ->
            map_core_type t ~onvar:(fun as_ ->
              if String.equal as_ aname
              then Typ.constr (Located.lident ~loc tdecl.ptype_name.txt) @@
                List.map tdecl.ptype_params ~f:fst
              else Typ.var ~loc as_
              ) |> helper
          | Ptyp_constr (cid, params) ->
            (* there for type 'a list = ('a,'a list) alist
             * we inherit plugin class for base type, for example (gmap):
             *  inherit ('a,'a2,'a list,'a2 list) gmap_alist
            **)
            k [Ctf.inherit_ ~loc @@ Cty.constr ~loc
                 (Located.mk ~loc @@ map_longident cid.txt
                    ~f:(sprintf "%s_%s" self#plugin_name))
                 (self#prepare_inherit_args_for_alias ~loc tdecl params)
              ]
          | Ptyp_tuple ts ->
            (* let's say we have predefined aliases for now *)
            helper @@ constr_of_tuple ~loc ts
          | Ptyp_variant (rows,_,_) ->
              let rr = List.map rows ~f:(function
              | Rinherit typ ->
                  (with_constr_typ typ
                     ~ok:(fun cid params ->
                       Ctf.inherit_ ~loc @@ Cty.constr ~loc
                         (Located.map (map_longident
                                         ~f:(sprintf "%s_%s" self#plugin_name)) cid)
                         (self#prepare_inherit_args_for_alias ~loc tdecl params)
                     )
                     ~fail:(fun () -> assert false)
                  )
              | Rtag (lab,_,_, typs) ->
                  Ctf.method_ ~loc (sprintf "c_%s" lab)
                    ~virt_flg:Concrete
                    (Typ.chain_arrow ~loc
                       ([self#default_inh] @ typs @ [self#default_syn tdecl]))
              )
              in
              k @@  rr
        | _ -> assert false
        in
        helper typ
    )
    ~onvariant:(fun cds ->
        k @@ List.map cds
          ~f:(fun cd ->
              match cd.pcd_args with
              | Pcstr_record _ -> assert false
              | Pcstr_tuple ts ->
                Ctf.method_ ~loc ~virt_flg:Concrete ("c_"^cd.pcd_name.txt) @@
                List.fold_right ~init:(self#default_syn tdecl)
                  (self#default_inh :: ts)
                  ~f:(Typ.arrow ~loc Nolabel)

          )
    )


  method make_inherit_args_for_alias ~loc ~is_self_rec tdecl do_typ cid cparams =
    let args =
      List.mapi cparams ~f:(fun i t ->
          (* printf "checking for arg with index (%d+1)\n%!" i; *)
          try List.Assoc.find_exn reinterpreted_args ~equal:Int.equal (i+1)
          with Caml.Not_found -> do_typ ~loc t
        )
    in
    (* for typ aliases we can cheat because first argument of constructor of type
               on rhs is self transformer function *)
    (* TODO: make consistent with self_arg_name *)
    (self#generate_for_variable ~loc "self") :: args

  (* When we got declaration of type alias via type application *)
  method got_constr ~loc ~is_self_rec tdecl do_typ cid cparams
      (k: class_field list ->'r) : 'r =
    (* printf "got a constr\n%!"; *)
    (* self#show_args; *)
    let ans args : class_field list =
      [ let typ_params = self#prepare_inherit_args_for_alias ~loc tdecl cparams in
        Cf.inherit_ ~loc @@ Cl.apply
          (Cl.constr ~loc
             (map_longident cid.txt ~f:(sprintf "%s_%s" self#plugin_name))
             typ_params)
          (nolabelize args)
      ]
    in

    let class_args =
      self#make_inherit_args_for_alias ~loc ~is_self_rec tdecl do_typ cid cparams
    in
    k @@ ans class_args


  (* When we met polymnorphic variant on RHS of type declaration *)
  (* method virtual got_polyvar: loc:location ->
   *   is_self_rec:(core_type -> bool) -> mutal_names:(string list) ->
   *   type_declaration ->
   *   (loc:Location.t -> core_type -> 'do_typ_res) ->
   *   row_field list ->
   *   (class_field list -> 'pvr) -> 'pvr *)

  method got_polyvar ~loc ~is_self_rec ~mutal_names tdecl do_typ rows k =
    List.concat_map rows ~f:(function
    | Rinherit typ ->
        with_constr_typ typ
            ~fail:(fun () -> failwith "type is not a constructor")
            ~ok:(fun cid params ->
                (* Hypothesis: it's almost an type alias *)
                self#got_constr ~loc ~is_self_rec tdecl do_typ cid params k
                (* let args = List.map params ~f:(do_typ ~loc) in
               *   let inh_params = self#prepare_inherit_args_for_alias ~loc
               *       tdecl params
               *   in
               *   Cf.inherit_ ~loc @@ Cl.apply
               *     (Cl.constr
               *        (map_longident cid.txt ~f:(sprintf "gmap_%s"))
               *        inh_params
               *     )
               *     (nolabelize ((Exp.sprintf ~loc "%s" self_arg_name)::args))
                 * ) *)
              )
    | Rtag (constr_name,_,_,args) ->
      (* Hypothesis: it's almost the same as constructor with a tuple of types  *)
      self#on_tuple_constr ~loc ~is_self_rec ~mutal_names tdecl (`Poly constr_name) args
        k


        (* let names = make_new_names ~prefix:"_arg" (List.length args) in
         *
         * [
         * Cf.method_concrete ~loc ("c_" ^ constr_name) @@
         * [%expr fun () -> [%e
         *   Exp.fun_list ~args:(List.map names ~f:(Pat.sprintf "%s")) @@
         *   self#generate_for_polyvar_tag ~loc ~is_self_rec ~mutal_names
         *     constr_name (List.zip_exn names args)
         *     [%expr assert false ] (fun x -> x)
         *
         * ]]
         * ] *)
    )

  method got_typedecl tdecl ~is_self_rec ~mutal_names (k: class_field list -> _) : _ =

    let loc = tdecl.ptype_loc in
    k @@
    visit_typedecl ~loc tdecl
    ~onmanifest:(fun typ ->
        let rec helper typ  =
          match typ.ptyp_desc with
          | Ptyp_alias (t, aname) ->
            map_core_type t ~onvar:(fun as_ ->
              if String.equal as_ aname
              then Typ.constr (Located.lident ~loc tdecl.ptype_name.txt) @@
                List.map tdecl.ptype_params ~f:fst
              else Typ.var ~loc as_
              ) |> helper
          | Ptyp_constr (cid, params) ->
              self#got_constr ~loc ~is_self_rec tdecl
                (self#do_typ_gen ~mutal_names ~is_self_rec)
                cid params (fun x -> x)

          | Ptyp_tuple ts ->
            (* let's say we have predefined aliases for now *)
            helper @@ constr_of_tuple ~loc ts
          | Ptyp_variant (rows,_,_) ->
            self#got_polyvar ~loc tdecl (self#do_typ_gen ~mutal_names ~is_self_rec)
              ~is_self_rec ~mutal_names rows (fun x -> x)
        | _ -> assert false
        in
        helper typ
    )
    ~onvariant:(fun cds -> self#on_variant ~mutal_names ~is_self_rec tdecl cds (fun x -> x))


  (* almost the same as `make_typ_of_class_argument` *)
  method make_typ_of_self_trf ~loc tdecl =
    let is_poly = is_polyvariant_tdecl tdecl in
    let openize_poly typ =
      let loc = typ.ptyp_loc in
      if is_poly then Typ.variant ~loc [Rinherit typ] Open None
      else typ
    in

    let subj_t = openize_poly @@ using_type ~typename:tdecl.ptype_name.txt tdecl
    in
    let syn_t  = self#default_syn tdecl in
    [%type: [%t subj_t] -> [%t syn_t] ]

  (* val name: <this> -> <this> -> <and that> -> <_not_ this> *)
  method make_typ_of_class_argument ~loc name =
    let subj_t = Typ.var ~loc name in
    let syn_t = self#syn_of_param ~loc name in
    [%type: [%t subj_t] -> [%t syn_t] ]

  (* val name : <typeof fa> -> ... -> <typeof fz> ->
                     <this type we are generating here>
  *)
  method make_RHS_typ_of_transformation ?subj_t ?syn_t tdecl =
    let loc = tdecl.ptype_loc in

    let subj_t = Option.value subj_t
        ~default:(using_type ~typename:tdecl.ptype_name.txt tdecl) in
    let syn_t  = Option.value syn_t  ~default:(self#default_syn tdecl) in
    [%type: [%t subj_t] -> [%t syn_t] ]

  method chain_inh_syn ~loc ?(inh_t=self#default_inh) ~syn_t subj_t =
    [%type: [%t inh_t] -> [%t subj_t] -> [%t syn_t] ]

  method wrap_tr_function_typ (typ: core_type) =
    (* let loc = typ.ptyp_loc in *)
    typ
    (* [%type:  [%t self#default_inh] -> [%t typ] ] *)

  method make_trans_function_typ tdecl =
    let loc = tdecl.ptype_loc in
    let type_ = self#make_RHS_typ_of_transformation tdecl in

    List.fold_right
      (map_type_param_names tdecl.ptype_params ~f:id)
      ~init:type_
      ~f:(fun name ->
          Typ.arrow ~loc Nolabel @@
          self#make_typ_of_class_argument ~loc name
          (* Typ.arrow ~loc Nolabel @@
           *  self#make_RHS_typ_of_transformation ~subj_t:(Typ.var name)
           *    ~syn_t:(self) tdecl *)
         )

  method make_trans_function_name tdecl =
    sprintf "%s_%s" self#plugin_name tdecl.ptype_name.txt

  method make_trans_functions_sig: loc:location ->
    is_rec:bool -> string list -> type_declaration list -> signature
    = fun ~loc ~is_rec mutal_names tdecls ->

      List.map tdecls ~f:(fun tdecl ->
          let type_ = self#make_trans_function_typ tdecl in
          Sig.value ~loc
            ~name:(self#make_trans_function_name tdecl)
            type_
        )

  method make_class_name ?(is_mutal=false) tdecl =
    sprintf "%s_%s%s" self#plugin_name tdecl.ptype_name.txt
      (if is_mutal then "_stub" else "")

  method wrap_tr_function_str ~loc tdecl gcata_on_new_expr =
    let body = gcata_on_new_expr [%expr self] in
    [%expr fun subj -> GT.fix0 (fun self ->
        [%e body] ()) subj
    ]

  (* let <plugin-name> fa ... fz = <this body> *)
  method make_trans_function_body ~loc ?(rec_typenames=[]) class_name tdecl =
    let arg_transfrs = map_type_param_names tdecl.ptype_params ~f:((^)"f") in
    self#wrap_tr_function_str ~loc tdecl
      (fun eself ->
         Exp.apply1 ~loc (Exp.sprintf ~loc "gcata_%s" tdecl.ptype_name.txt) @@
         Exp.apply ~loc (Exp.new_ ~loc @@ Located.lident ~loc class_name) @@
         (nolabelize @@
          List.map rec_typenames ~f:(Exp.sprintf ~loc "%s_%s" self#plugin_name)
          @ [eself]
          @ List.map arg_transfrs ~f:(Exp.sprintf ~loc "%s")
         )
      )

  method make_trans_functions: loc:location ->
    is_rec:bool -> string list -> type_declaration list -> structure_item
    = fun ~loc ~is_rec mutal_names tdecls ->
      (* we will generate mutally recursive showers here *)
      let on_tdecl tdecl =
        let cur_name = tdecl.ptype_name.txt in
        let others =
          List.filter mutal_names ~f:(String.(<>) cur_name)
        in
        value_binding ~loc
          ~pat:(Pat.sprintf ~loc "%s" @@ self#make_trans_function_name tdecl)
          ~expr:(
            let class_name = self#make_class_name ~is_mutal:(not (List.is_empty mutal_names))
                tdecl
            in
            let arg_transfrs = map_type_param_names tdecl.ptype_params ~f:((^)"f") in
            Exp.fun_list ~loc
              ~args:(List.map arg_transfrs ~f:(Pat.sprintf ~loc "%s"))
              (self#make_trans_function_body ~loc ~rec_typenames:others class_name tdecl)

          )
      in
      let flag = if List.length mutal_names = 1 then Nonrecursive else Recursive in
      Str.value ~loc ~flag @@ List.map tdecls ~f:on_tdecl


  method do_single_sig ~(loc:location) ~(is_rec: bool) (tdecl: type_declaration) : signature =
    List.concat
    [ self#make_class_sig ~loc ~is_rec tdecl []
    ; self#make_trans_functions_sig ~loc ~is_rec [] [tdecl]
    ]

  method do_single ~loc ~is_rec tdecl =
    [ self#make_class ~loc ~is_rec tdecl []
    ; self#make_trans_functions ~loc ~is_rec [] [tdecl]
    ]

  method do_mutals ~(loc: Location.t) ~(is_rec: bool) tdecls : structure_item list =
    (* for mutal recursion we need to generate two classes and one function *)
    let mut_names = List.map tdecls ~f:(fun td -> td.ptype_name.txt) in
    List.map tdecls ~f:(fun tdecl ->
        self#make_class ~loc ~is_rec:true tdecl @@
        List.filter mut_names ~f:(String.(<>) tdecl.ptype_name.txt)
      ) @
    (self#make_trans_functions ~loc ~is_rec:true mut_names tdecls) ::
    (self#make_shortend_class  ~loc ~is_rec:true mut_names tdecls)


  method on_record_constr : type_declaration -> constructor_declaration ->
    label_declaration list -> 'on_record_result
    = fun _ _ _ ->
    failwith "not_implemented"

  method virtual on_tuple_constr : loc:Location.t ->
    is_self_rec:(core_type -> bool) ->
    mutal_names:(string list) ->
    type_declaration ->
    [ `Normal of string | `Poly of string ] ->
    core_type list -> (class_field list -> 'r) -> 'r

  method on_variant tdecl ~mutal_names ~is_self_rec cds k =
    let loc = tdecl.ptype_loc in
    k @@
    List.concat_map cds ~f:(fun cd ->
        match cd.pcd_args with
        | Pcstr_tuple ts ->
            self#on_tuple_constr ~loc ~mutal_names ~is_self_rec
              tdecl (`Normal cd.pcd_name.txt) ts (fun x -> x)
        | Pcstr_record ls -> self#on_record_constr tdecl cd ls
      )


  method virtual generate_for_polyvar_tag : loc:location ->
    is_self_rec:(core_type -> bool) -> mutal_names:(string list) ->
    string -> (string*core_type) list -> expression ->
    (expression -> 'x) -> 'x


  method generate_for_variable ~loc varname =
    Exp.sprintf "f%s" varname

  method app_transformation_expr trf inh subj =
    let loc = trf.pexp_loc in
    [%expr [%e trf ] [%e subj]]

  method abstract_trf ~loc k =
    (* [%expr fun inh subj -> [%e k [%expr inh ] [%expr subj]]] *)
    [%expr fun subj -> [%e k [%expr assert false ] [%expr subj]]]

  method extract_transformation ~loc etrf = etrf


  (* TODO: decide expression of which type should be returned here *)
  (* do_type_gen will return an expression which after being applied
   * to inherited attribute and subject will return synthetized one
   *)
  method do_typ_gen ~loc ~mutal_names ~is_self_rec t =
    let rec helper t =
      match t.ptyp_desc with
      | Ptyp_var s -> self#extract_transformation ~loc @@ self#generate_for_variable ~loc s
      | Ptyp_tuple params ->
        self#abstract_trf ~loc (fun einh esubj ->
            self#app_transformation_expr
              (Exp.apply_nolabeled ~loc
                 (Exp.sprintf "%s_tuple%d" self#plugin_name (List.length params))
                 (List.map ~f:helper params)
              )
              einh esubj
          )
      | Ptyp_constr (_,_) when is_self_rec t ->
        (* self#generate_for_variable ~loc "self" *)
        self#extract_transformation ~loc @@ Exp.ident ~loc self_arg_name
      | Ptyp_constr ({txt},params) ->
          (* in this place it will be easier to have all plugin in single value *)
          let trf_expr =
            match txt with
            | Lident s when List.mem mutal_names s ~equal:String.equal ->
              (* we should use local trf function *)
              Exp.ident_of_long ~loc @@
              map_longident ~f:(sprintf "%s_%s" self#plugin_name) txt
            | _ ->
                [%expr let (module Op) =
                         [%e Exp.ident_of_long txt] in
                  [%e
                    Exp.ident_of_long ~loc @@
                    Ldot (Lident "Op", self#plugin_name) ]
                ]
          in
        self#abstract_trf ~loc (fun einh esubj ->
            self#app_transformation_expr
              (self#extract_transformation ~loc  @@
               Exp.apply_nolabeled ~loc
                 trf_expr
                 (List.map ~f:helper params)
              )
              einh esubj
          )
        | Ptyp_variant (rows, _, maybe_labels) -> begin
          let oninherit einh esubj typs cident varname =
            self#app_transformation_expr
              (Exp.apply_nolabeled ~loc
                Exp.(ident_of_long ~loc @@
                     map_longident cident
                       ~f:(Printf.sprintf "%s_%s" self#plugin_name))
                (List.map typs ~f:helper)
              )
              einh esubj
            in
            let onrow lab bindings =
              self#generate_for_polyvar_tag ~loc ~is_self_rec ~mutal_names
                lab bindings
                [%expr inh] (fun x -> x)
            in
            self#abstract_trf ~loc (fun einh esubj ->
            (* let k e = [%expr fun inh foo  -> [%e e]] in *)
              prepare_patt_match_poly ~loc esubj rows maybe_labels
                ~onrow
                ~onlabel:(fun _ _ -> [%expr 1])
                ~oninherit:(oninherit einh esubj)
            )
          end
        | _ -> failwith "Finish it!"
    in
    helper t


end
