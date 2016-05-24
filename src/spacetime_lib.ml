(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*           Mark Shinwell and Leo White, Jane Street Europe              *)
(*                                                                        *)
(*   Copyright 2015--2016 Jane Street Group LLC                           *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

open Raw_spacetime_lib

module Position = struct

  type t = Printexc.location

  let filename { Printexc.filename } = filename

  let line_number { Printexc.line_number } = line_number

  let start_char { Printexc.start_char } = start_char

  let end_char { Printexc.end_char } = end_char

  let print ppf t =
    let open Printexc in
    Format.fprintf ppf "%s{%d:%d-%d}"
      t.filename t.line_number t.start_char t.end_char

end

module Location = struct

  type t =
    { address: Int64.t;
      symbol: string option;
      position : Position.t option;
      foreign : bool; }

  let address { address } = address

  let symbol { symbol } = symbol

  let position { position } = position

  let foreign { foreign } = foreign

  let compare t1 t2 =
    Int64.compare t1.address t2.address

  let create_ocaml ?executable ~frame_table pc =
    let address = Program_counter.OCaml.to_int64 pc in
    let symbol = None in
    let foreign = false in
    let position =
      try
        let slot = Frame_table.find_exn pc frame_table in
        Printexc.Slot.location slot
      with Not_found -> None
    in
    { address; symbol; position; foreign; }

  let create_foreign ?executable pc =
    let program_counter = Program_counter.Foreign.to_int64 pc in
    let position =
      match executable with
      | None -> None
      | Some elf_locations ->
        match Elf_locations.resolve elf_locations ~program_counter with
        | None -> None
        | Some (filename, line_number) ->
          let location =
            { Printexc.
              filename;
              line_number;
              start_char = -1;
              end_char = -1;
            }
          in
          Some location
    in
    let symbol =
      match executable with
      | None -> None
      | Some elf_locations ->
        Elf_locations.function_at_pc elf_locations ~program_counter
    in
    { address = program_counter;
      symbol;
      position;
      foreign = true;
    }

  let print ppf t =
    match t.position with
    | Some pos -> Position.print ppf pos
    | None ->
        match t.symbol with
        | Some symbol -> Format.fprintf ppf "%s" symbol
        | None -> Format.fprintf ppf "%Ld" t.address

end

module Backtrace = struct

  type t = Location.t list

  let rec compare b1 b2 =
    match b1, b2 with
    | [], [] -> 0
    | l1 :: b1, l2 :: b2 ->
      let c = Location.compare l1 l2 in
      if c <> 0 then c
      else compare b1 b2
    | _ :: _, [] -> 1
    | [], _ :: _ -> -1

  let rec print ppf = function
    | [] -> ()
    | [loc] -> Location.print ppf loc
    | loc :: res ->
      Format.fprintf ppf "%a %a"
        Location.print loc
        print res

end

module Entry = struct

  type t =
    { thread : int;
      backtrace : Backtrace.t;
      blocks : int;
      words : int;
      allocations : int; }

  let backtrace { backtrace } = backtrace

  let blocks { blocks } = blocks

  let words { words } = words

  let allocations { allocations } = allocations

  let compare t1 t2 =
    let c = compare t1.thread t2.thread in
    if c <> 0 then c
    else Backtrace.compare t1.backtrace t2.backtrace

  let hash = Hashtbl.hash

end

module Entry_sorted_by_words_highest_first = struct
  type t = Entry.t

  let compare entry1 entry2 =
    Pervasives.compare entry2.Entry.words entry1.Entry.words

  let hash = Entry.hash
end

module Entries = Set.Make (Entry)

module Entries_sorted_by_words_highest_first =
  Set.Make (Entry_sorted_by_words_highest_first)

module Stats = struct

  type t =
    { gc: Gc_stats.t;
      words_scanned : int;
      words_scanned_with_profinfo : int; }

  let minor_words t = Gc_stats.minor_words t.gc
  let promoted_words t = Gc_stats.promoted_words t.gc
  let major_words t = Gc_stats.major_words t.gc
  let minor_collections t = Gc_stats.minor_collections t.gc
  let major_collections t = Gc_stats.major_collections t.gc
  let heap_words t = Gc_stats.heap_words t.gc
  let heap_chunks t = Gc_stats.heap_chunks t.gc
  let compactions t = Gc_stats.compactions t.gc
  let top_heap_words t = Gc_stats.top_heap_words t.gc

  let words_scanned { words_scanned } = words_scanned

  let words_scanned_with_profinfo { words_scanned_with_profinfo } =
    words_scanned_with_profinfo

end

module Snapshot = struct

  type t =
    { time : float;
      stats : Stats.t;
      entries : Entries.t;
      raw : Heap_snapshot.t;
    }

  let time { time } = time

  let stats { stats } = stats

  let entries { entries } = entries

  let entries_sorted_by_words_highest_first { entries; _ } =
    Entries.fold (fun entry acc ->
        Entries_sorted_by_words_highest_first.add entry acc)
      entries
      Entries_sorted_by_words_highest_first.empty

  let create ~snapshot ~entries =
    let time = Heap_snapshot.timestamp snapshot in
    let gc = Heap_snapshot.gc_stats snapshot in
    let words_scanned = Heap_snapshot.words_scanned snapshot in
    let words_scanned_with_profinfo =
      Heap_snapshot.words_scanned_with_profinfo snapshot
    in
    let stats =
      { Stats.gc; words_scanned; words_scanned_with_profinfo; }
    in
    { time; stats; entries; raw = snapshot; }

  let raw t = t.raw
end

module Series = struct

  type t = Snapshot.t list

  let rec fold_ocaml_indirect_calls ?executable ~frame_table ~shape_table
            visited f backtrace acc callee =
    let node = Trace.OCaml.Indirect_call_point.Callee.callee_node callee in
    let acc =
      fold_node ?executable ~frame_table ~shape_table visited f backtrace
        acc node
    in
    let next = Trace.OCaml.Indirect_call_point.Callee.next callee in
    match next with
    | None -> acc
    | Some callee ->
      fold_ocaml_indirect_calls ?executable ~frame_table ~shape_table
        visited f backtrace acc callee

  and fold_ocaml_fields ?executable ~frame_table ~shape_table
        visited f backtrace acc field =
    let acc =
      match Trace.OCaml.Field.classify field with
      | Trace.OCaml.Field.Allocation alloc ->
        let pc = Trace.OCaml.Allocation_point.program_counter alloc in
        let loc = Location.create_ocaml ?executable ~frame_table pc in
        let annot = Trace.OCaml.Allocation_point.annotation alloc in
        f (loc :: backtrace) annot acc
      | Trace.OCaml.Field.Direct_call (Trace.OCaml.Field.To_ocaml call) ->
        let site = Trace.OCaml.Direct_call_point.call_site call in
        let loc = Location.create_ocaml ?executable ~frame_table site in
        let node = Trace.OCaml.Direct_call_point.callee_node call in
        fold_ocaml_node ?executable ~frame_table ~shape_table
          visited f (loc :: backtrace) acc node
      | Trace.OCaml.Field.Direct_call (Trace.OCaml.Field.To_foreign call) ->
        let site = Trace.OCaml.Direct_call_point.call_site call in
        let loc = Location.create_ocaml ?executable ~frame_table site in
        let node = Trace.OCaml.Direct_call_point.callee_node call in
        fold_foreign_node ?executable ~frame_table ~shape_table
          visited f (loc :: backtrace) acc node
      | Trace.OCaml.Field.Direct_call
          (Trace.OCaml.Field.To_uninstrumented _) ->
        acc
      | Trace.OCaml.Field.Indirect_call call ->
        let site = Trace.OCaml.Indirect_call_point.call_site call in
        let loc = Location.create_ocaml ?executable ~frame_table site in
        let callee = Trace.OCaml.Indirect_call_point.callees call in
        match callee with
        | None -> acc
        | Some callee ->
          fold_ocaml_indirect_calls ?executable ~frame_table ~shape_table
            visited f (loc :: backtrace) acc callee
    in
    match Trace.OCaml.Field.next field with
    | None -> acc
    | Some field ->
      fold_ocaml_fields ?executable ~frame_table ~shape_table
        visited f backtrace acc field

  and fold_ocaml_node ?executable ~frame_table ~shape_table visited f
        backtrace acc node =
    if Trace.Node.Set.mem (Trace.Node.of_ocaml_node node) !visited then acc
    else begin
      visited := Trace.Node.Set.add (Trace.Node.of_ocaml_node node) !visited;
      let acc =
         fold_ocaml_node
           ?executable ~frame_table ~shape_table visited f backtrace acc
           (Trace.OCaml.Node.next_in_tail_call_chain node)
      in
      let acc =
        match Trace.OCaml.Node.fields node ~shape_table with
        | None -> acc
        | Some fields ->
          fold_ocaml_fields
            ?executable ~frame_table ~shape_table visited f backtrace acc fields
      in
      acc
    end

  and fold_foreign_fields ?executable ~frame_table ~shape_table
        visited f backtrace acc field =
    let acc =
      match Trace.Foreign.Field.classify field with
      | Trace.Foreign.Field.Allocation alloc ->
        let pc = Trace.Foreign.Allocation_point.program_counter alloc in
        let loc = Location.create_foreign ?executable pc in
        let annot = Trace.Foreign.Allocation_point.annotation alloc in
        f (loc :: backtrace) annot acc
      | Trace.Foreign.Field.Call call ->
        let site = Trace.Foreign.Call_point.call_site call in
        let loc = Location.create_foreign ?executable site in
        let node = Trace.Foreign.Call_point.callee_node call in
        fold_node ?executable ~frame_table ~shape_table
          visited f (loc :: backtrace) acc node
    in
    match Trace.Foreign.Field.next field with
    | None -> acc
    | Some field ->
      fold_foreign_fields ?executable ~frame_table ~shape_table
        visited f backtrace acc field

  and fold_foreign_node ?executable ~frame_table ~shape_table visited f
        backtrace acc node =
    match Trace.Foreign.Node.fields node with
    | None -> acc
    | Some field ->
      fold_foreign_fields ?executable ~frame_table ~shape_table
        visited f backtrace acc field

  and fold_node ?executable ~frame_table ~shape_table visited f backtrace
        acc node =
    match Trace.Node.classify node with
    | Trace.Node.OCaml node ->
      fold_ocaml_node ?executable ~frame_table ~shape_table visited f
        backtrace acc node
    | Trace.Node.Foreign node ->
      fold_foreign_node ?executable ~frame_table ~shape_table visited f
        backtrace acc node

  let fold_trace ?executable ~frame_table ~shape_table f acc trace =
    match Trace.root trace with
    | None -> acc
    | Some node ->
      let visited = ref Trace.Node.Set.empty in
      fold_node ?executable ~frame_table ~shape_table visited f [] acc node

  let fold_traces ?executable ~series ~frame_table ~shape_table f acc =
    let num_threads = Heap_snapshot.Series.num_threads series in
    let rec loop acc n =
      if n >= num_threads then acc
      else begin
        let normal =
          Heap_snapshot.Series.trace series Heap_snapshot.Series.Normal n
        in
        let acc =
          match normal with
          | None -> acc
          | Some trace ->
            fold_trace ?executable ~frame_table ~shape_table (f n) acc trace
        in
        let finaliser =
          Heap_snapshot.Series.trace series Heap_snapshot.Series.Finaliser n
        in
        let acc =
          match finaliser with
          | None -> acc
          | Some trace ->
            fold_trace ?executable ~frame_table ~shape_table (f ~-n) acc trace
        in
        loop acc (n + 1)
      end
    in
    loop acc 0

  let live_table ~snapshot =
    let entries = Heap_snapshot.entries snapshot in
    let length = Heap_snapshot.Entries.length entries in
    let tbl = Hashtbl.create 42 in
    for entry = 0 to length - 1 do
      let annotation = Heap_snapshot.Entries.annotation entries entry in
      let num_blocks = Heap_snapshot.Entries.num_blocks entries entry in
      let num_words =
        Heap_snapshot.Entries.num_words_including_headers entries entry
      in
      assert (not (Hashtbl.mem tbl annotation));
      Hashtbl.add tbl annotation (num_blocks, num_words)
    done;
    tbl

  let allocations_table ~snapshot =
    let tbl = Hashtbl.create 42 in
    let rec loop next =
      match next with
      | None -> ()
      | Some allocation ->
        let annotation = Heap_snapshot.Allocations.annotation allocation in
        let num_words =
          Heap_snapshot.Allocations.num_words_including_headers allocation
        in
        Hashtbl.add tbl annotation num_words;
        let next = Heap_snapshot.Allocations.next allocation in
        loop next
    in
    loop (Heap_snapshot.allocations snapshot);
    tbl

  let create ?executable path =
    let series = Heap_snapshot.Series.read ~path in
    let executable =
      match executable with
      | None -> None
      | Some executable ->
        Some (Elf_locations.create ~elf_executable:executable)
    in
    let frame_table = Heap_snapshot.Series.frame_table series in
    let shape_table = Heap_snapshot.Series.shape_table series in
    let length = Heap_snapshot.Series.num_snapshots series in
    let snapshots =
      let rec loop acc n =
        if n < 0 then List.rev acc
        else begin
          let snapshot = Heap_snapshot.Series.snapshot series ~index:n in
          loop (snapshot :: acc) (n - 1)
        end
      in
      loop [] (length - 1)
    in
    let init =
      List.map
        (fun snapshot ->
           let live_table = live_table ~snapshot in
           let alloc_table = allocations_table ~snapshot in
             snapshot, live_table, alloc_table, Entries.empty)
        snapshots
    in
    let accumulate thread backtrace annot accs =
      List.map
        (fun ((snapshot, live_table, alloc_table, entries) as acc) ->
           match Hashtbl.find live_table annot with
           | (blocks, words) -> begin
               match Hashtbl.find alloc_table annot with
               | allocations ->
                 let entry =
                   { Entry.thread; backtrace; blocks; words; allocations }
                 in
                 let entries = Entries.add entry entries in
                 (snapshot, live_table, alloc_table, entries)
               | exception Not_found -> acc
             end
           | exception Not_found -> acc)
        accs
    in
    let snapshots =
      fold_traces ?executable ~series ~frame_table ~shape_table accumulate init
    in
    let snapshots =
      List.map
        (fun (snapshot, _, _, entries) -> Snapshot.create ~snapshot ~entries)
        snapshots
    in
    snapshots

end
