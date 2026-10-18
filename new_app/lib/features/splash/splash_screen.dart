import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../core/widgets/klick_logo.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';

/// One-shot startup gate.
///
/// `false` until the cold-start splash sequence has completed (or been
/// skipped outright under reduced motion). The router refuses to leave
/// `/splash` while this is `false`, and once `true` it stays `true` for
/// the whole app run — navigating, logging out or hitting a session
/// expiry can therefore never replay the splash.
final splashGateProvider = StateProvider<bool>((ref) => false);

/// Brand background of the startup splash — fixed deep navy in every
/// theme, so the first frame is the brand palette rather than whatever
/// light/dark scaffold happens to follow it.
const Color kBrandSplashBackground = Color(0xFF0A1830);

/// Minimum on-screen time of the startup sequence. The animation
/// controller *is* the clock: it keeps scheduling frames for exactly this
/// long, so `pumpAndSettle` in tests cannot leave the splash early, and
/// the gate can never open on a blank frame.
const Duration kSplashSequenceDuration = Duration(milliseconds: 1600);

/// The brand wordmark. A product name, not UI copy: it is never
/// translated (same policy as `AboutScreen`'s `kDeveloperName`), which is
/// why it is a named const instead of an `AppStrings.t` lookup.
const String kBrandWordmark = 'Klick POS';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;
  bool _started = false;

  /// Progress of one timeline step at [t], clamped to its window.
  double _seg(double start, double end, double t, Curve curve) {
    if (t <= start) return 0;
    if (t >= end) return 1;
    return curve.transform((t - start) / (end - start));
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kSplashSequenceDuration,
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        ref.read(splashGateProvider.notifier).state = true;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      // No motion to show: open the gate after the first painted frame so
      // the router's refresh listener never fires mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(splashGateProvider.notifier).state = true;
      });
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final checking = ref.watch(authProvider).status == AuthStatus.checking;
    final textTheme = Theme.of(context).textTheme;

    return ColoredBox(
      color: kBrandSplashBackground,
      child: Scaffold(
        key: const Key('splash-screen'),
        backgroundColor: Colors.transparent,
        body: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _reduceMotion ? 1.0 : _controller.value;
              final logoT = _seg(0, 0.35, t, Curves.easeOutCubic);
              final logoScale = 0.92 + 0.08 * _seg(0, 0.4, t, Curves.easeOutCubic);
              final wordmarkT = _seg(0.3, 0.62, t, Curves.easeOutCubic);
              final taglineT = _seg(0.55, 0.82, t, Curves.easeOut);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: logoT,
                    child: Transform.scale(
                      scale: logoScale,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.darkAccent.withValues(
                                alpha: 0.45 * logoT,
                              ),
                              blurRadius: 56,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                        child: const KlickPosLogo(
                          key: Key('splash-logo'),
                          size: 120,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 36),
                  Opacity(
                    opacity: wordmarkT,
                    child: Transform.translate(
                      offset: Offset(0, 14 * (1 - wordmarkT)),
                      child: Text(
                        kBrandWordmark,
                        key: const Key('splash-wordmark'),
                        textDirection: TextDirection.ltr,
                        style: (textTheme.headlineSmall ?? const TextStyle())
                            .copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 34,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: taglineT,
                    child: Text(
                      AppStrings.t('about_description', loc),
                      key: const Key('splash-tagline'),
                      textAlign: TextAlign.center,
                      style: (textTheme.bodyMedium ?? const TextStyle())
                          .copyWith(
                        color: Colors.white70,
                        fontSize: 15,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  // Space is always reserved so the layout cannot shift
                  // when the spinner (loading only) appears or leaves.
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: checking
                        ? const CircularProgressIndicator(
                            key: Key('splash-progress'),
                            strokeWidth: 3,
                            color: Colors.white70,
                          )
                        : const SizedBox.expand(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
