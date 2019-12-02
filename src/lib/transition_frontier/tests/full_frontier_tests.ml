open Async_kernel
open Core_kernel
open Signature_lib
open Coda_base
open Coda_transition
open Frontier_base
open Deferred.Let_syntax

let%test_module "Full_frontier tests" =
  ( module struct
    let () =
      Backtrace.elide := false ;
      Async.Scheduler.set_record_backtraces true

    let logger = Logger.null ()

    let accounts_with_secret_keys = Genesis_ledger.accounts

    let max_length = 5

    let gen_breadcrumb =
      Breadcrumb.For_tests.gen ~logger ?verifier:None ?trust_system:None
        ~accounts_with_secret_keys

    let gen_breadcrumb_seq =
      Breadcrumb.For_tests.gen_seq ~logger ?verifier:None ?trust_system:None
        ~accounts_with_secret_keys

    module Transfer = Ledger_transfer.Make (Ledger) (Ledger)

    let add_breadcrumb frontier breadcrumb =
      let diffs = Full_frontier.calculate_diffs frontier breadcrumb in
      ignore (Full_frontier.apply_diffs frontier diffs)

    let add_breadcrumbs frontier = List.iter ~f:(add_breadcrumb frontier)

    let create_frontier () =
      let base_hash = Frontier_hash.empty in
      let consensus_local_state =
        Consensus.Data.Local_state.create Public_key.Compressed.Set.empty
          ~genesis_ledger:Genesis_ledger.t
      in
      let root_ledger =
        Or_error.ok_exn
          (Transfer.transfer_accounts
             ~src:(Lazy.force Genesis_ledger.t)
             ~dest:(Ledger.create ()))
      in
      let root_data =
        let open Root_data in
        { transition=
            Lazy.force
              (External_transition.genesis ~genesis_ledger:Genesis_ledger.t
                 ~base_proof:Coda_base.Proof.dummy)
        ; staged_ledger= Staged_ledger.create_exn ~ledger:root_ledger }
      in
      Full_frontier.create ~logger ~root_data
        ~root_ledger:(Ledger.Any_ledger.cast (module Ledger) root_ledger)
        ~base_hash ~consensus_local_state ~max_length

    let%test_unit "Should be able to find a breadcrumbs after adding them" =
      Quickcheck.test gen_breadcrumb ~trials:4 ~f:(fun make_breadcrumb ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let frontier = create_frontier () in
              let root = Full_frontier.root frontier in
              let%map breadcrumb = make_breadcrumb root in
              add_breadcrumb frontier breadcrumb ;
              let queried_breadcrumb =
                Full_frontier.find_exn frontier
                  (Breadcrumb.state_hash breadcrumb)
              in
              [%test_eq: Breadcrumb.t] breadcrumb queried_breadcrumb ) )

    let%test_unit "Constructing a better branch should change the best tip" =
      let gen_branches =
        let open Quickcheck.Generator.Let_syntax in
        let%bind short_branch = gen_breadcrumb_seq 2 in
        let%map long_branch = gen_breadcrumb_seq 3 in
        (short_branch, long_branch)
      in
      Quickcheck.test gen_branches ~trials:4
        ~f:(fun (make_short_branch, make_long_branch) ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let frontier = create_frontier () in
              let test_best_tip ?message breadcrumb =
                [%test_eq: State_hash.t] ?message
                  (Breadcrumb.state_hash breadcrumb)
                  (Breadcrumb.state_hash @@ Full_frontier.best_tip frontier)
              in
              let root = Full_frontier.root frontier in
              let%bind short_branch = make_short_branch root in
              let%map long_branch = make_long_branch root in
              test_best_tip root ~message:"best tip should start as root" ;
              add_breadcrumbs frontier short_branch ;
              test_best_tip
                (List.last_exn short_branch)
                ~message:"best tip should change when short branch is added" ;
              add_breadcrumb frontier (List.hd_exn long_branch) ;
              test_best_tip
                (List.last_exn short_branch)
                ~message:
                  "best tip should not change when only part of long branch \
                   is added" ;
              add_breadcrumbs frontier (List.tl_exn long_branch) ;
              test_best_tip
                (List.last_exn long_branch)
                ~message:"best tip should change when all of best tip is added"
          ) )

    let%test_unit "The root should be updated after (> max_length) nodes are \
                   added in sequence" =
      let test_eq ?message = [%test_eq: Breadcrumb.t] ?equal:None ?message in
      let test_not_eq ?message =
        let message = Option.map message ~f:(fun m -> "not " ^ m) in
        [%test_eq: Breadcrumb.t] ?message ~equal:(fun a b ->
            not (Breadcrumb.equal a b) )
      in
      Quickcheck.test
        (gen_breadcrumb_seq (max_length * 2))
        ~trials:4
        ~f:(fun make_seq ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let frontier = create_frontier () in
              let root = Full_frontier.root frontier in
              let%map seq = make_seq root in
              ignore
              @@ List.fold seq ~init:1 ~f:(fun i breadcrumb ->
                     let pre_root = Full_frontier.root frontier in
                     add_breadcrumb frontier breadcrumb ;
                     let post_root = Full_frontier.root frontier in
                     if i > max_length then
                       test_not_eq pre_root post_root
                         ~message:
                           "roots should be different after max_length \
                            breadcrumbs are added"
                     else
                       test_eq pre_root post_root
                         ~message:
                           "roots should be the same before max_length \
                            breadcrumbs" ;
                     i + 1 ) ) )

    let%test_unit "The length of the longest branch should never be greater \
                   than max_length" =
      let gen =
        Quickcheck.Generator.Let_syntax.(
          Int.gen_incl max_length (max_length * 2) >>= gen_breadcrumb_seq)
      in
      Quickcheck.test gen ~trials:4 ~f:(fun make_seq ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let frontier = create_frontier () in
              let root = Full_frontier.root frontier in
              let%map breadcrumbs = make_seq root in
              List.iter breadcrumbs ~f:(fun b ->
                  add_breadcrumb frontier b ;
                  [%test_pred: int] (( >= ) max_length)
                    (List.length
                       Full_frontier.(
                         path_map frontier (best_tip frontier) ~f:Fn.id)) ) )
      )

    let%test_unit "Common ancestor can be reliably found" =
      let ancestor_length = (max_length / 2) - 1 in
      let gen =
        let open Quickcheck.Generator.Let_syntax in
        let%bind ancestors = gen_breadcrumb_seq ancestor_length in
        let%bind branch_a =
          Int.gen_incl 1 (max_length / 2) >>= gen_breadcrumb_seq
        in
        let%map branch_b =
          Int.gen_incl 1 (max_length / 2) >>= gen_breadcrumb_seq
        in
        (ancestors, branch_a, branch_b)
      in
      Quickcheck.test gen ~trials:4
        ~f:(fun (make_ancestors, make_branch_a, make_branch_b) ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let frontier = create_frontier () in
              let root = Full_frontier.root frontier in
              let%bind ancestors = make_ancestors root in
              let youngest_ancestor = List.last_exn ancestors in
              let%bind branch_a = make_branch_a youngest_ancestor in
              let%map branch_b = make_branch_b youngest_ancestor in
              let tip_a, tip_b =
                (List.last_exn branch_a, List.last_exn branch_b)
              in
              add_breadcrumbs frontier ancestors ;
              add_breadcrumbs frontier (branch_a @ branch_b) ;
              [%test_eq: State_hash.t]
                (Full_frontier.common_ancestor frontier tip_a tip_b)
                (Breadcrumb.state_hash youngest_ancestor) ) )
  end )
