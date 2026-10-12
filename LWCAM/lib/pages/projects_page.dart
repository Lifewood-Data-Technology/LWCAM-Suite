// Project list screen in the LWCAM capture app, opened from home_page.dart.
// Picking a project leads to project_area_page.dart. Data comes from
// projects_controller.dart.
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/projects_controller.dart';
import '../models/project.dart';
import '../widgets/session_app_bar_actions.dart';
import 'project_area_page.dart';

/// Read-only project list — the projects assigned to the signed-in account in
/// ANY role, from the local pulled snapshot. Create/edit/delete and the
/// metadata template editor moved to the separate LWCam Admin app, which
/// writes PostgreSQL directly.
///
/// No longer admin-gated: every role reaches its work through a project now, so
/// this is the one list. What each project OFFERS still depends on the roles
/// held on it — that decision lives in [ProjectAreaPage].
class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<ProjectsController>()
        ? Get.find<ProjectsController>()
        : Get.put(ProjectsController());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: c.load,
          ),
          ...sessionAppBarActions(context),
        ],
      ),
      body: Obx(() {
        if (c.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (c.errorMessage.value != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(c.errorMessage.value!, textAlign: TextAlign.center),
            ),
          );
        }
        final visible = c.projects;
        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            ...visible.map((p) => _projectTile(context, p)),
            if (visible.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'No projects assigned to you. Contact an administrator to '
                    'be assigned one.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _projectTile(BuildContext context, Project p) {
    final dateText =
        '${p.startDate.year}-${p.startDate.month.toString().padLeft(2, '0')}-${p.startDate.day.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const CircleAvatar(child: Icon(Icons.folder_special_outlined)),
        title: Text(p.name,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              'ID: ${p.projectId}'
              '${(p.countryLocationCode ?? '').isNotEmpty ? '  ·  ${p.countryLocationCode}' : ''}'
              '  ·  Start: $dateText',
              style: const TextStyle(fontSize: 14)),
        ),
        trailing: const Icon(Icons.chevron_right),
        // Picking a project is now the first step, not just a look: it leads to
        // that project's dashboard or its QC queue.
        onTap: () => Get.to(() => ProjectAreaPage(project: p)),
      ),
    );
  }
}
