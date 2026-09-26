// Shared viewport layout rules for the POS screen.
//
// Both the screen (cart panel sizing) and the compact toast (whether a
// bottom-centered card can sit at 24 px without covering the cart footer)
// need these — they live here so neither file has to import the other.
enum PosLayoutMode { wide, medium, narrow }

PosLayoutMode posLayoutModeFor(double width) {
  if (width >= 1100) return PosLayoutMode.wide;
  if (width >= 800) return PosLayoutMode.medium;
  return PosLayoutMode.narrow;
}

/// Adaptive cart panel width (UX FIX #8). Prefer a usable cashier cart
/// over shrinking controls. Floors: 420 (wide/normal), 380 (medium).
double posCartWidthFor(double viewportWidth) {
  if (viewportWidth >= 1400) return 480; // target 460–500
  if (viewportWidth >= 1100) return 440; // target 420–460
  if (viewportWidth >= 800) return 400; // target 380–420
  return viewportWidth; // narrow: full-width drawer
}
