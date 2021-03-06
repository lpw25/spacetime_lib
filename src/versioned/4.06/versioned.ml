open Raw_spacetime_lib

let direct_call_count = Trace.OCaml.Direct_call_point.call_count

let indirect_call_count = Trace.OCaml.Indirect_call_point.Callee.call_count

let has_call_counts = Heap_snapshot.Series.has_call_counts

let map_file fd ?pos kind layout shared dim =
  Bigarray.array1_of_genarray
    (Unix.map_file fd ?pos kind layout shared [|dim|])
