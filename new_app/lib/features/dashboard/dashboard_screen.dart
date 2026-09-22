import 'package:flutter/material.dart';

/// Dashboard placeholder inside the authenticated shell.
/// The shell provides the Scaffold/AppBar — this is content only.
/// Real dashboard business features belong to Phase 5 (not started).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Dashboard - Phase 2'),
    );
  }
}
