import 'package:flutter/material.dart';

import '../models/project.dart';

/// Placeholder for a per-project dashboard.
///
/// Deliberately empty of invented numbers: a dashboard showing plausible but
/// wrong figures is worse than one that says it is not built yet, because the
/// first kind gets believed. Reached from [ProjectAreaPage].
class ProjectDashboardPage extends StatelessWidget {
  const ProjectDashboardPage({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${project.name} - Dashboard')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.insights_outlined, size: 56, color: cs.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                'Dashboard coming soon',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Progress and quality figures for ${project.name} will appear '
                'here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
