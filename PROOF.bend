import Base
import ./LAWS.bend as Laws
import ./src/layout.bend as L
import ./examples/camera_args.bend as A
import ./src/viewer_policy.bend as P
import ./src/modes.bend as M
import ./src/image.bend as I
import ./src/jpeg.bend as J
import ./src/jpeg_tables.bend as JT
import ./src/imgproc.bend as IP
import ./src/draw.bend as D

# Proofs of LAWS.bend. Run `bend PROOF.bend` (and `--verdict`) before committing.

# --- Lemmas ---

# n <= n
def Proof.le_refl(n: Nat) -> {Nat.is_le(n, n) == True{} : Bool}:
  match n:
    case 0n:
      {==}
    case 1n+p:
      Proof.le_refl(p)

# n <= n + p
def Proof.le_add(n: Nat, p: Nat) -> {Nat.is_le(n, Nat.add(n, p)) == True{} : Bool}:
  match n:
    case 0n:
      match p:
        case 0n:
          {==}
        case 1n+q:
          {==}
    case 1n+m:
      Proof.le_add(m, p)

# not (have + 1 + missing <= have)
def Proof.le_short(have: Nat, missing: Nat) ->
  {Nat.is_le(Nat.add(have, 1n+missing), have) == False{} : Bool}:
  match have:
    case 0n:
      {==}
    case 1n+h:
      Proof.le_short(h, missing)

# --- Laws ---

def Laws.stride_per_pixel(w):
  {==}

def Laws.stride_tight(w):
  Proof.le_refl(L.Layout.min_stride(w))

def Laws.stride_padded(w, pad):
  Proof.le_add(L.Layout.min_stride(w), pad)

def Laws.stride_short(have, missing):
  Proof.le_short(have, missing)

def Laws.config_needs_program():
  {==}

def Laws.config_default(prog):
  {==}

def Laws.config_count_and_snapshot(prog, path):
  {==}

def Laws.config_rejects_zero(prog, rest):
  {==}

def Laws.fps_decimals_padded():
  {==}

def Laws.first_error_kept(first, later):
  {==}

def Laws.viewer_private_by_default():
  {==}

def Laws.viewer_private_refuses_network(port, token, csrf, route, req):
  {==}

def Laws.viewer_switch_is_local_only(sharing, on, port, token, csrf, req):
  match sharing:
    case P.Private{}:
      {==}
    case P.Shared{}:
      {==}

def Laws.viewer_token_required(port, token, csrf, route, req, wrong):
  match route:
    case P.SetSharing{on}:
      {==}
    case P.Index{}:
      %Equal.sym(Bool, String.eq(P.Request.token(req), token), False{}, wrong) :
        {P.Policy.allowed(P.Policy.token_gate(_)) == False{} : Bool}
      {==}
    case P.Page{n}:
      %Equal.sym(Bool, String.eq(P.Request.token(req), token), False{}, wrong) :
        {P.Policy.allowed(P.Policy.token_gate(_)) == False{} : Bool}
      {==}
    case P.Stream{n}:
      %Equal.sym(Bool, String.eq(P.Request.token(req), token), False{}, wrong) :
        {P.Policy.allowed(P.Policy.token_gate(_)) == False{} : Bool}
      {==}
    case P.NotFound{}:
      %Equal.sym(Bool, String.eq(P.Request.token(req), token), False{}, wrong) :
        {P.Policy.allowed(P.Policy.token_gate(_)) == False{} : Bool}
      {==}
    case P.ViewPage{n}:
      %Equal.sym(Bool, String.eq(P.Request.token(req), token), False{}, wrong) :
        {P.Policy.allowed(P.Policy.token_gate(_)) == False{} : Bool}
      {==}
    case P.ViewStream{n}:
      %Equal.sym(Bool, String.eq(P.Request.token(req), token), False{}, wrong) :
        {P.Policy.allowed(P.Policy.token_gate(_)) == False{} : Bool}
      {==}

def Laws.viewer_foreign_host_refused(sharing, port, token, csrf, route, req, foreign):
  %Equal.sym(Bool, P.Policy.local_host_ok(port, P.Request.host(req)), False{}, foreign) :
    {P.Policy.allowed(P.Policy.check_local(port, csrf, route, req, _)) == False{} : Bool}
  {==}

def Laws.viewer_cross_site_refused(sharing, port, token, csrf, route, req, host_ok, cross):
  %Equal.sym(Bool, P.Policy.local_host_ok(port, P.Request.host(req)), True{}, host_ok) :
    {P.Policy.allowed(P.Policy.check_local(port, csrf, route, req, _)) == False{} : Bool}
  %Equal.sym(Bool, String.eq(P.Request.fetch_site(req), "cross-site"), True{}, cross) :
    {P.Policy.allowed(P.Policy.check_local_site(port, csrf, route, req, _)) == False{} : Bool}
  {==}

def Laws.viewer_private_stops_network_streams(now, since):
  {==}

def Laws.viewer_new_epoch_stops_network_streams(now, since, changed):
  %Equal.sym(Bool, U32.is_eq(now, since), False{}, changed) :
    {_ == False{} : Bool}
  {==}

def Laws.viewer_routes():
  {==}

def Laws.modes_none_from_nothing(want):
  match want:
    case M.Largest{}:
      {==}
    case M.Size{w, h}:
      {==}

def Laws.modes_single_mode(mode):
  {==}

def Laws.modes_facetime_hd():
  {==}

def Laws.modes_4k_webcam():
  {==}

def Laws.modes_from_numbers():
  {==}

def Laws.image_rgba_layout():
  {==}

def Laws.image_camera_swap():
  {==}

def Laws.image_luma_range():
  {==}

def Laws.image_rows_per_band():
  {==}

def Laws.image_bands_keep_order():
  {==}

def Laws.image_get_2x2():
  {==}

def Laws.image_get_column():
  {==}

def Laws.image_brightness():
  {==}

def Laws.image_get_two_bands():
  {==}

def Laws.viewer_view_routes():
  {==}

def Laws.jpeg_zigzag_permutation():
  {==}

def Laws.jpeg_huffman_codes():
  {==}

def Laws.jpeg_coefficient_bits():
  {==}

def Laws.jpeg_byte_stuffing():
  {==}

def Laws.jpeg_restart_interval():
  {==}

def Laws.imgproc_crop_refuses_past_edge():
  {==}

def Laws.imgproc_crop_maps_pixels():
  {==}

def Laws.imgproc_invert():
  {==}

def Laws.imgproc_threshold():
  {==}

def Laws.imgproc_flip_x():
  {==}

def Laws.imgproc_set_pixel():
  {==}

def Laws.imgproc_histogram():
  {==}

def Laws.imgproc_rectangle():
  {==}

def Laws.imgproc_downscale():
  {==}

def Laws.draw_bbox():
  {==}

def Laws.draw_outside_untouched():
  {==}
