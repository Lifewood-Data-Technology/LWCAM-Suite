// Per-project task chooser in the LWCAM capture app, between the project
// list (projects_page.dart) and the work itself (dashboard or capture).
// Cards depend on the roles held on the chosen project.
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../models/app_user.dart';
import '../models/project.dart';
import '../widgets/session_app_bar_actions.dart';
import 'project_dashboard_page.dart';

/// What an account can do once it has picked a project.
///
/// This layer exists so the choice of PROJECT comes before the choice of TASK.
/// Quality Check used to be a top-level destination listing every project's
/// tasks at once, which meant an admin working one project had to read past
/// everyone else's.
///
/// The cards are not fixed: each appears only when the account holds that role
/// ON THIS PROJECT (see [AuthController.rolesForProject]), so an admin who also
/// captures gets Dashboard + Capture on the projects they capture into and
/// Dashboard alone on the rest. With one card there is nothing to choose, so
/// the list is skipped and its destination opens directly — which is what makes
/// a capture-only or QC-only account land straight on its work.
class ProjectAreaPage extends StatelessWidget {
  const ProjectAreaPage({super.key, required this.project});

  final Project project;

  /// Fixed order regardless of which subset applies, so a card does not move
  /// position between one project and the next.
  /// QC is deliberately absent: the role is still granted, but reviewing
  /// happens in the QC console now (Phase 8), so it contributes no card here
  /// and the two switches below can never be reached with it.
  static const _order = [UserRole.admin, UserRole.capture];

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    return Obx(() {
      final held = auth.rolesForProject(project);
      final cards = [for (final r in _order) if (held.contains(r)) r];

      if (cards.isEmpty) {
        // Two ways to land here, and they need different answers. A sync pull
        // can revoke the last grant while this page is open — that IS lost
        // access. But since Phase 8 an account holding only `qc` ON THIS
        // PROJECT also lands here: Projects lists the union of every role's
        // grants (AuthController.visibleProjects) while _order no longer
        // carries QC, so its grant is intact and simply has nothing behind it
        // in LWCAM. Telling that reviewer their access was revoked sends them
        // to an administrator over a working account.
        return Scaffold(
          appBar: AppBar(title: Text(project.name)),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                held.contains(UserRole.qc)
                    ? 'Reviewing happens in the QC console now — open it in a '
                        'browser. Nothing else on this project is yours in '
                        'LWCAM.'
                    : 'You no longer have access to this project. Contact an '
                        'administrator.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }

      // One job: open it directly. A one-item list is a button pressed twice.
      if (cards.length == 1) return _destination(cards.single);

      return Scaffold(
        appBar: AppBar(
          title: Text(project.name),
          actions: sessionAppBarActions(context),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  'ID: ${project.projectId}',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final r in cards) _card(context, r),
            ],
          ),
        ),
      );
    });
  }

  Widget _card(BuildContext context, UserRole role) {
    switch (role) {
      case UserRole.admin:
        return _AreaCard(
          icon: Icons.insights_outlined,
          title: 'Dashboard',
          subtitle: 'Progress and quality figures for this project.',
          onTap: () => Get.to(() => ProjectDashboardPage(project: project)),
        );
      case UserRole.capture:
        return _AreaCard(
          icon: Icons.photo_camera_outlined,
          title: 'Capture',
          subtitle: 'Pull, review and transfer images into this project.',
          // Routed by the controller, not pushed here: entry has to clear the
          // device-registry gate (one device is bound to one project) before
          // the active project is set, and it lands on /boxes or /gallery
          // depending on whether metadata keying is on. A refusal raises its
          // own modal and leaves this list on screen.
          //
          // replaceRoute: false so Back comes back to THESE cards. Replacing
          // this page instead sent Back one level too far, to the projects
          // list.
          onTap: () => Get.find<AuthController>()
              .enterCaptureWithProject(project, replaceRoute: false),
        );
      case UserRole.qc:
        throw StateError('QC holds no card here; it is not in _order.');
    }
  }

  /// The single-card case, opened in place of the list.
  Widget _destination(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return ProjectDashboardPage(project: project);
      case UserRole.qc:
        throw StateError('QC has no destination here; it is not in _order.');
      case UserRole.capture:
        return _CaptureHandoff(project: project);
    }
  }
}

class _AreaCard extends StatelessWidget {
  const _AreaCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        leading: Icon(icon, size: 28, color: cs.primary),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(subtitle, style: const TextStyle(fontSize: 14)),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// A project whose ONLY card is Capture has nothing to draw: entering capture
/// replaces this route. Routing is not allowed during build, so fire it once
/// the first frame exists and hold a spinner until it does.
class _CaptureHandoff extends StatefulWidget {
  const _CaptureHandoff({required this.project});

  final Project project;

  @override
  State<_CaptureHandoff> createState() => _CaptureHandoffState();
}

class _CaptureHandoffState extends State<_CaptureHandoff> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final entered = await Get.find<AuthController>()
          .enterCaptureWithProject(widget.project);
      // Refused, and the gate has already said why in its own modal. Go back
      // to the list rather than sit on a spinner that will never resolve.
      if (!entered && mounted) Get.back();
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
