(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module D = Debug.Debugger(struct let name="xapi" end)
open D

let vmpr_plugin = "vmpr"

let protect_now ~__context ~vmpp = 
  let vmpp_uuid = Db.VMPP.get_uuid ~__context ~self:vmpp in
  let args = [ "vmpp_uuid", vmpp_uuid ] in
  Xapi_plugins.call_plugin
    (Context.get_session_id __context)
    vmpr_plugin
    "protect_now"
    args

let archive_now ~__context ~snapshot = 
  let snapshot_uuid = Db.VM.get_uuid ~__context ~self:snapshot in
  let args = [ "snapshot_uuid", snapshot_uuid ] in
  Xapi_plugins.call_plugin
    (Context.get_session_id __context)
    vmpr_plugin
    "archive_now"
    args

let set_is_backup_running ~__context ~self ~value =
  Db.VMPP.set_is_backup_running ~__context ~self ~value

let set_is_archive_running ~__context ~self ~value =
  Db.VMPP.set_is_archive_running ~__context ~self ~value

(* mini datamodel for type and key value restrictions in the vmpp map fields *)
type key_type = Enum of string list | EnumSet of string list | IntRange of int*int | String | ReqValue of string | Secret
let schedule_days_enum = ["Monday";"Tuesday";"Wednesday";"Thursday";"Friday";"Saturday";"Sunday"]
let schedule_frequency_hourly = "hourly"
let schedule_frequency_daily = "daily"
let schedule_frequency_weekly = "weekly"
let frequency_order = [schedule_frequency_hourly;schedule_frequency_daily;schedule_frequency_weekly]
let schedule_min_enum = ["0";"15";"30";"45"]
let backup_schedule_field = "backup-schedule"
let archive_target_config_field = "archive-target-config"
let archive_schedule_field = "archive-schedule"
let alarm_config_field = "alarm-config"
let archive_target_type_cifs = "cifs"
let archive_target_type_nfs = "nfs"
let is_alarm_enabled_true = "true"
let is_alarm_enabled_false = "false"
let btype b = if b then is_alarm_enabled_true else is_alarm_enabled_false
let schedule_min_default = List.hd schedule_min_enum
let schedule_hour_default = "0"
let schedule_days_default = List.hd schedule_days_enum 

let more_frequent_than ~a ~b = (* is a more frequent than b? *)
  if a=b then false
  else
  if (List.mem a frequency_order) && (List.mem b frequency_order)
  then (let rec tst xs = match xs with
    |[]->false
    |x::xs->if a=x then true else if b=x then false else tst xs
    in tst frequency_order
  )
  else false (*incomparable*)

(* relations between map types and map keys *)
let archive_schedule_frequency_enum = [schedule_frequency_daily;schedule_frequency_weekly]
let backup_schedule_frequency_enum = schedule_frequency_hourly :: archive_schedule_frequency_enum
let backup_schedule_frequency_hourly_keys = backup_schedule_field,[schedule_frequency_hourly,[Datamodel.vmpp_schedule_min, ((Enum schedule_min_enum), schedule_min_default)]]
let backup_schedule_frequency_daily_keys = backup_schedule_field,[schedule_frequency_daily,[Datamodel.vmpp_schedule_hour, ((IntRange(0,23)), schedule_hour_default);Datamodel.vmpp_schedule_min, ((Enum schedule_min_enum), schedule_min_default)]]
let backup_schedule_frequency_weekly_keys = backup_schedule_field,[schedule_frequency_weekly,[Datamodel.vmpp_schedule_hour, ((IntRange(0,23)), schedule_hour_default);Datamodel.vmpp_schedule_min, ((Enum schedule_min_enum), schedule_min_default);Datamodel.vmpp_schedule_days, ((EnumSet schedule_days_enum), schedule_days_default)]]
let archive_schedule_frequency_daily_keys = match backup_schedule_frequency_daily_keys with f,k -> archive_schedule_field,k
let archive_schedule_frequency_weekly_keys = match backup_schedule_frequency_weekly_keys with f,k -> archive_schedule_field,k
let archive_target_config_type_cifs_keys = archive_target_config_field,[archive_target_type_cifs,[Datamodel.vmpp_archive_target_config_location, ((String), "");Datamodel.vmpp_archive_target_config_username, ((String), "");Datamodel.vmpp_archive_target_config_password, ((Secret), "")]]
let archive_target_config_type_nfs_keys = archive_target_config_field,[archive_target_type_nfs,[Datamodel.vmpp_archive_target_config_location, ((String), "")]]

(* look-up structures, contain allowed map keys in a specific map type *)
let backup_schedule_keys = backup_schedule_field,(List.map (fun (f,[k])->k) [backup_schedule_frequency_hourly_keys;backup_schedule_frequency_daily_keys;backup_schedule_frequency_weekly_keys])
let archive_target_config_keys = archive_target_config_field,(List.map (fun (f,[k])->k) [archive_target_config_type_cifs_keys;archive_target_config_type_nfs_keys])
let archive_schedule_keys = archive_schedule_field,(List.map (fun (f,[k])->k) [archive_schedule_frequency_daily_keys;archive_schedule_frequency_weekly_keys])
let alarm_config_keys = alarm_config_field,[is_alarm_enabled_true,["email_address", ((String), "");"smtp_server", ((String), "");"smtp_port", ((IntRange(1,65535)), "25")]]

(* look-up structures, contain allowed map keys in all map types *)
let backup_schedule_all_keys = backup_schedule_field,["",(List.fold_left (fun acc (sf,ks)->acc@ks) [] (let (f,kss)=backup_schedule_keys in kss))]
let archive_target_config_all_keys = archive_target_config_field,["",(List.fold_left (fun acc (sf,ks)->acc@ks) [] (let (f,kss)=archive_target_config_keys in kss))]
let archive_schedule_all_keys = archive_schedule_field,["",(List.fold_left (fun acc (sf,ks)->acc@ks) [] (let (f,kss)=archive_schedule_keys in kss))]
let alarm_config_all_keys = alarm_config_field,["",(List.fold_left (fun acc (sf,ks)->acc@ks) [] (let (f,kss)=alarm_config_keys in kss))]

(* functions to assert the mini datamodel above *)

let err field key value =
  let msg = if key="" then field else field^":"^key in
  raise (Api_errors.Server_error (Api_errors.invalid_value, [msg;value]))

let mem value range =
  try Some
    (List.find
      (fun r->(String.lowercase value)=(String.lowercase r))
      range
    )
  with Not_found -> None

let assert_value ~field ~key ~attr ~value =
  let err v = err field key v in
  let (ty,default) = attr in
  match ty with
	| Enum range -> (match (mem value range) with None->err value|Some v->v)
	| EnumSet range -> (* enumset is a comma-separated string *)
      let vs = Stringext.String.split ',' value in
      List.fold_right 
       (fun v acc->match (mem v range) with
        |None->err v
        |Some v->if acc="" then v else (v^","^acc)
       )
       vs
       ""
  | IntRange (min,max) ->
      let v=try int_of_string value with _->err value in
      if (v<min or v>max) then err value else value
  | ReqValue required_value -> if value <> required_value then err value else value
  | Secret|String -> value
  
let with_ks ~kss ~fn =
  let field,kss=kss in
  let corrected_values = List.filter (fun cv->cv<>None) (List.map (fun ks-> fn field ks) kss) in
  if List.length corrected_values < 1
  then []
  else (match List.hd corrected_values with None->[]|Some cv->cv)

let assert_req_values ~field ~ks ~vs =
  (* each required values in this ks must match the one in the vs map this key/value belongs to*) 
  let req_values = List.fold_right
    (fun (k,attr) acc->match attr with(ReqValue rv),_->(k,rv)::acc|_->acc) ks []
  in
  (if vs<>[] then
    List.iter (fun (k,rv)->
      if (List.mem_assoc k vs) then (if rv<>(List.assoc k vs) then err field k rv)
    ) req_values
  )

let merge xs ys = (* uses xs elements to overwrite ys elements *)
  let nys = List.map (fun (ky,vy)->if List.mem_assoc ky xs then (ky,(List.assoc ky xs)) else (ky,vy)) ys in
  let nxs = List.filter (fun (kx,_)->not(List.mem_assoc kx nys)) xs in
  nxs@nys

let assert_key ~field ~ks ~key ~value =
  debug "assert_key: field=%s key=[%s] value=[%s]" field key value;
  (* check if the key and value conform to this ks *)
  (if not (List.mem_assoc key ks)
   then
     err field key value
   else
     assert_value ~field ~key ~attr:(List.assoc key ks) ~value
  )

let assert_keys ~ty ~ks ~value ~db =
  let value = merge value db in
  with_ks ~kss:ks ~fn:
  (fun field (xt,ks) ->
    debug "assert_keys: field=%s xt=[%s] ty=[%s]" field xt ty;
    if (xt=ty) then Some
    (
      assert_req_values ~field ~ks ~vs:value;
      (* for this ks, each key value must be valid *)
      List.map (fun (k,v)-> k,(assert_key ~field ~ks ~key:k ~value:v)) value
    )
    else None
  )

let assert_all_keys ~ty ~ks ~value ~db =
  let value = merge value db in
  with_ks ~kss:ks ~fn:
  (fun field (xt,ks)->
    debug "assert_all_keys: field=%s xt=[%s] ty=[%s]" field xt ty;
    if (xt=ty) then Some
    (
      assert_req_values ~field ~ks ~vs:value;

(* 
   currently disabled: too strong for api-bindings:
   - api-bindings change first the type, and later the maps,
   - so we cannot currently assert that all map keys are present:

      (* for this ks, all keys must be present *)
      let ks_keys = Listext.List.setify (let (x,y)=List.split ks in x) in
		  let value_keys = Listext.List.setify (let (x,y)=List.split value in x) in
		  let diff = Listext.List.set_difference ks_keys value_keys in
      (if diff<>[] then err field (List.hd diff) "");
*)

      (* add missing keys with default values *)
      let value = List.map (fun (k,(kt,default))->if List.mem_assoc k value then (k,(List.assoc k value)) else (k,default)) ks in

      (* remove extra unexpected keys *)
      let value = List.fold_right (fun (k,v) acc->if List.mem_assoc k ks then (k,v)::acc else acc) value [] in

      (* for this ks, each key value must be valid *)
      List.map (fun (k,v)-> k,(assert_key ~field ~ks ~key:k ~value:v)) value
    )
    else None
  )

let assert_non_required_key ~ks ~key ~db =
  ()
(* (* currently disabled: unfortunately, key presence integrity is too strict for the CLI, which needs to remove and add keys at will *)
  with_ks ~kss:ks ~fn:
  (fun ks->
    assert_req_values ~ks ~key ~value:"" ~db;
    (* check if the key is not expected in this ks *)
    if (List.mem_assoc key ks) then err key ""
	)
*)

let map_password_to_secret ~__context ~new_password ~db =
  let secret_uuid = Uuid.to_string
    (if List.mem_assoc Datamodel.vmpp_archive_target_config_password db
    then 
      Uuid.of_string
        (List.assoc Datamodel.vmpp_archive_target_config_password db)
    else
      Uuid.null
    )
  in
  try
    let secret_ref = Db.Secret.get_by_uuid ~__context ~uuid:secret_uuid in
    (* the uuid is a valid uuid in the secrets table *)
    (if (new_password <> secret_uuid)
    then (* new_password is not the secret uuid, then update secret *)
    Db.Secret.set_value ~__context ~self:secret_ref ~value:new_password
    );
    secret_uuid
  with e -> (
    (* uuid doesn't exist in secrets table, create a new one *)
    ignore (ExnHelper.string_of_exn e);
    let new_secret_ref = Ref.make() in
    let new_secret_uuid = Uuid.to_string(Uuid.make_uuid()) in
    Db.Secret.create ~__context ~ref:new_secret_ref ~uuid:new_secret_uuid ~value:new_password;
    new_secret_uuid
  )

let map_any_passwords_to_secrets ~__context ~value ~db =
  if List.mem_assoc Datamodel.vmpp_archive_target_config_password value
  then 
    let secret = map_password_to_secret ~__context ~db
      ~new_password:(List.assoc Datamodel.vmpp_archive_target_config_password value)
    in
    merge [(Datamodel.vmpp_archive_target_config_password,secret)] value
  else
    value

let remove_any_secrets ~__context ~config ~key =
  if List.mem_assoc key config
  then
		let secret_uuid = List.assoc key config in
    try
      let secret_ref = Db.Secret.get_by_uuid ~__context ~uuid:secret_uuid in 
      Db.Secret.destroy ~__context ~self:secret_ref
    with _ -> (* uuid doesn't exist in secrets table, leave it alone *)
      ()

let assert_set_backup_frequency ~backup_frequency ~backup_schedule=
  let ty = XMLRPC.From.string (API.To.vmpp_backup_frequency backup_frequency) in
  assert_all_keys ~ty ~ks:backup_schedule_keys ~value:backup_schedule ~db:backup_schedule

let assert_archive_target_type_not_none ~archive_target_type ~archive_target_config =
  let ty = XMLRPC.From.string (API.To.vmpp_archive_target_type archive_target_type) in
  let archive_target_config = assert_all_keys ~ty ~ks:archive_target_config_keys ~value:archive_target_config ~db:archive_target_config in
  archive_target_config

let assert_archive_target_type ~archive_target_type ~archive_target_config ~archive_frequency ~archive_schedule =
  match archive_target_type with
	| `none -> (* reset archive_frequency to never *)
      ([], `never, [])
  | _-> 
      let archive_target_config = assert_archive_target_type_not_none ~archive_target_type ~archive_target_config in
     (archive_target_config,archive_frequency,archive_schedule)

let assert_set_archive_frequency ~archive_frequency ~archive_target_type ~archive_target_config ~archive_schedule =
  match archive_target_type with
  |`none -> (
    match archive_frequency with
    |`never-> ([],[])
    |_->err "archive_target_type" "" (XMLRPC.From.string (API.To.vmpp_archive_target_type archive_target_type))
    )
  |_ -> (
    match archive_frequency with
	  |`never -> (archive_target_config,[])
	  |`always_after_backup ->
      let archive_target_config = assert_archive_target_type_not_none ~archive_target_type ~archive_target_config in
      (archive_target_config,[])
    | _ ->
      let archive_target_config = assert_archive_target_type_not_none ~archive_target_type ~archive_target_config in
		  let ty = XMLRPC.From.string (API.To.vmpp_archive_frequency archive_frequency) in
      let archive_schedule = assert_all_keys ~ty ~ks:archive_schedule_keys ~value:archive_schedule ~db:archive_schedule in
      (archive_target_config,archive_schedule)
    )

let assert_set_is_alarm_enabled ~is_alarm_enabled ~alarm_config =
  if is_alarm_enabled
  then (
    assert_all_keys ~ty:(btype is_alarm_enabled) ~ks:alarm_config_keys ~value:alarm_config ~db:alarm_config
  )
  else (* do not erase alarm_config if alarm is disabled *)
    alarm_config

let assert_frequency ~archive_frequency ~backup_frequency =
  let a = XMLRPC.From.string (API.To.vmpp_archive_frequency archive_frequency) in
  let b = XMLRPC.From.string (API.To.vmpp_backup_frequency backup_frequency) in
  if (more_frequent_than ~a ~b)
  then
    raise (Api_errors.Server_error (Api_errors.vmpp_archive_more_frequent_than_backup,[]))

(* == the setters with customized key cross-integrity checks == *)

(* 1/3: values of non-map fields can only change if their corresponding maps contain the expected keys *)

let set_backup_frequency ~__context ~self ~value =
  let archive_frequency = Db.VMPP.get_archive_frequency ~__context ~self in
  assert_frequency ~archive_frequency ~backup_frequency:value;
  let backup_schedule = Db.VMPP.get_backup_schedule ~__context ~self in
  let new_backup_schedule = assert_set_backup_frequency ~backup_frequency:value ~backup_schedule in
  Db.VMPP.set_backup_frequency ~__context ~self ~value;
  (* update dependent maps *)
  Db.VMPP.set_backup_schedule ~__context ~self ~value:new_backup_schedule

let set_archive_frequency ~__context ~self ~value =
  let backup_frequency = Db.VMPP.get_backup_frequency ~__context ~self in
  assert_frequency ~archive_frequency:value ~backup_frequency;
  let archive_schedule = (Db.VMPP.get_archive_schedule ~__context ~self) in
  let archive_target_config = (Db.VMPP.get_archive_target_config ~__context ~self) in
  let archive_target_type = (Db.VMPP.get_archive_target_type ~__context ~self) in
  let (new_archive_target_config,new_archive_schedule) = assert_set_archive_frequency ~archive_frequency:value ~archive_target_type ~archive_target_config ~archive_schedule in
  Db.VMPP.set_archive_frequency ~__context ~self ~value;
  (* update dependent maps *)
  Db.VMPP.set_archive_target_config ~__context ~self ~value:new_archive_target_config;
  Db.VMPP.set_archive_schedule ~__context ~self ~value:new_archive_schedule

let set_archive_target_type ~__context ~self ~value =
  let archive_target_config = Db.VMPP.get_archive_target_config ~__context ~self in
  let archive_frequency = Db.VMPP.get_archive_frequency ~__context ~self in
  let archive_schedule = Db.VMPP.get_archive_schedule ~__context ~self in
  let (new_archive_target_config,new_archive_frequency,new_archive_schedule) = assert_archive_target_type ~archive_target_type:value ~archive_target_config ~archive_frequency ~archive_schedule in
  Db.VMPP.set_archive_target_type ~__context ~self ~value;
  (* update dependent maps *)
  Db.VMPP.set_archive_target_config ~__context ~self ~value:new_archive_target_config;
  Db.VMPP.set_archive_frequency ~__context ~self ~value:new_archive_frequency;
  Db.VMPP.set_archive_schedule ~__context ~self ~value:new_archive_schedule

let set_is_alarm_enabled ~__context ~self ~value =
  let alarm_config = Db.VMPP.get_alarm_config ~__context ~self in
  let new_alarm_config =  assert_set_is_alarm_enabled ~is_alarm_enabled:value ~alarm_config in
  Db.VMPP.set_is_alarm_enabled ~__context ~self ~value;
  (* update dependent maps *)
  Db.VMPP.set_alarm_config ~__context ~self ~value:new_alarm_config

(* 2/3: values of map fields can change as long as the key names and values are valid *)

let set_backup_schedule ~__context ~self ~value =
  let value = assert_keys ~ty:"" ~ks:backup_schedule_all_keys ~value ~db:(Db.VMPP.get_backup_schedule ~__context ~self) in
  Db.VMPP.set_backup_schedule ~__context ~self ~value

let add_to_backup_schedule ~__context ~self ~key ~value =
  let value = List.assoc key (assert_keys ~ty:"" ~ks:backup_schedule_all_keys ~value:[(key,value)] ~db:(Db.VMPP.get_backup_schedule ~__context ~self)) in
  Db.VMPP.add_to_backup_schedule ~__context ~self ~key ~value

let set_archive_target_config ~__context ~self ~value =
  let config = (Db.VMPP.get_archive_target_config ~__context ~self) in
  assert_keys ~ty:"" ~ks:archive_target_config_all_keys ~value ~db:config;
	let value = map_any_passwords_to_secrets ~__context ~value ~db:config in
  Db.VMPP.set_archive_target_config ~__context ~self ~value

let add_to_archive_target_config ~__context ~self ~key ~value =
  let config = (Db.VMPP.get_archive_target_config ~__context ~self) in
  assert_keys ~ty:"" ~ks:archive_target_config_all_keys ~value:[(key,value)] ~db:config;
  let value =
    if key=Datamodel.vmpp_archive_target_config_password
		then (map_password_to_secret ~__context ~db:config ~new_password:value)
		else value
  in
  Db.VMPP.add_to_archive_target_config ~__context ~self ~key ~value

let set_archive_schedule ~__context ~self ~value =
  let value = assert_keys ~ty:"" ~ks:archive_schedule_all_keys ~value ~db:(Db.VMPP.get_archive_schedule ~__context ~self) in
  Db.VMPP.set_archive_schedule ~__context ~self ~value

let add_to_archive_schedule ~__context ~self ~key ~value =
  let value = List.assoc key (assert_keys ~ty:"" ~ks:archive_schedule_all_keys ~value:[(key,value)] ~db:(Db.VMPP.get_archive_schedule ~__context ~self)) in
  Db.VMPP.add_to_archive_schedule ~__context ~self ~key ~value

let set_alarm_config ~__context ~self ~value =
  assert_keys ~ty:"" ~ks:alarm_config_all_keys ~value ~db:(Db.VMPP.get_alarm_config ~__context ~self);
  Db.VMPP.set_alarm_config ~__context ~self ~value

let add_to_alarm_config ~__context ~self ~key ~value =
  assert_keys ~ty:"" ~ks:alarm_config_all_keys ~value:[(key,value)] ~db:(Db.VMPP.get_alarm_config ~__context ~self);
  Db.VMPP.add_to_alarm_config ~__context ~self ~key ~value

(* 3/3: the CLI requires any key in any map to be removed at will *)

let remove_from_backup_schedule ~__context ~self ~key =
  assert_non_required_key ~ks:backup_schedule_keys ~key ~db:(Db.VMPP.get_backup_schedule ~__context ~self);
  Db.VMPP.remove_from_backup_schedule ~__context ~self ~key

let remove_from_archive_target_config ~__context ~self ~key =
  let db = (Db.VMPP.get_archive_target_config ~__context ~self) in
  assert_non_required_key ~ks:archive_target_config_keys ~key ~db;
  remove_any_secrets ~__context ~config:db ~key:Datamodel.vmpp_archive_target_config_password;
  Db.VMPP.remove_from_archive_target_config ~__context ~self ~key

let remove_from_archive_schedule ~__context ~self ~key =
  assert_non_required_key ~ks:archive_schedule_keys ~key ~db:(Db.VMPP.get_archive_schedule ~__context ~self);
  Db.VMPP.remove_from_archive_schedule ~__context ~self ~key

let remove_from_alarm_config ~__context ~self ~key =
  assert_non_required_key ~ks:alarm_config_keys ~key ~db:(Db.VMPP.get_alarm_config ~__context ~self);
  Db.VMPP.remove_from_alarm_config ~__context ~self ~key

(* constructors/destructors *)

let create ~__context ~name_label ~name_description ~is_policy_enabled
  ~backup_type ~backup_retention_value ~backup_frequency ~backup_schedule ~backup_last_run_time
  ~archive_target_type ~archive_target_config ~archive_frequency ~archive_schedule  ~archive_last_run_time
  ~is_alarm_enabled ~alarm_config
: API.ref_VMPP =

  (* assert all provided field values, key names and key values are valid *)
  assert_keys ~ty:(XMLRPC.From.string (API.To.vmpp_backup_frequency backup_frequency)) ~ks:backup_schedule_keys ~value:backup_schedule ~db:[];
  assert_keys ~ty:(XMLRPC.From.string (API.To.vmpp_archive_frequency archive_frequency)) ~ks:archive_schedule_keys ~value:archive_schedule ~db:[];
  assert_keys ~ty:(XMLRPC.From.string (API.To.vmpp_archive_target_type archive_target_type)) ~ks:archive_target_config_keys ~value:archive_target_config ~db:[];
  assert_keys ~ty:(btype is_alarm_enabled) ~ks:alarm_config_keys ~value:alarm_config ~db:[];

  (* assert inter-field constraints and fix values if possible *)
  let backup_schedule = assert_set_backup_frequency ~backup_frequency ~backup_schedule in
  let (archive_target_config,archive_schedule) = assert_set_archive_frequency ~archive_frequency ~archive_target_type ~archive_target_config ~archive_schedule in 
  let alarm_config = assert_set_is_alarm_enabled ~is_alarm_enabled ~alarm_config in
  let (archive_target_config,_,_) = assert_archive_target_type ~archive_target_type ~archive_target_config ~archive_frequency ~archive_schedule in

	let archive_target_config = map_any_passwords_to_secrets ~__context ~value:archive_target_config ~db:[] in

  (* assert frequency constraints *)
  assert_frequency ~archive_frequency ~backup_frequency;

  let ref=Ref.make() in
  let uuid=Uuid.to_string (Uuid.make_uuid()) in
  Db.VMPP.create ~__context ~ref ~uuid
    ~name_label ~name_description ~is_policy_enabled
    ~backup_type ~backup_retention_value
    ~backup_frequency ~backup_schedule ~backup_last_run_time
    ~is_backup_running:false ~is_archive_running:false
    ~archive_target_type ~archive_target_config
    ~archive_frequency ~archive_schedule ~archive_last_run_time
    ~is_alarm_enabled ~alarm_config ~recent_alerts:[];
  ref

let destroy ~__context ~self = 
  let vms = Db.VMPP.get_VMs ~__context ~self in
  if List.length vms > 0
  then ( (* we can't delete a VMPP that contains VMs *)
    raise (Api_errors.Server_error (Api_errors.vmpp_has_vm,[]))
  )
  else ( 
    let archive_target_config = (Db.VMPP.get_archive_target_config ~__context ~self) in
    remove_any_secrets ~__context ~config:archive_target_config ~key:Datamodel.vmpp_archive_target_config_password;
    Db.VMPP.destroy ~__context ~self
  )
