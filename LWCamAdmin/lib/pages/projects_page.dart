// Projects screen of LWCam Admin (the app that manages users, projects, devices
// and this station's database connection for the LWCAM suite). Lists projects
// and offers create, edit, delete and "Edit template" (opens the metadata
// template editor). All data changes go through ProjectsController, which
// saves via the admin store; this file holds only the list and the dialogs.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/projects_controller.dart';
import '../models/project.dart';
import '../services/snackbar_service.dart';
import '../theme/app_colors.dart';
import 'template_editor_page.dart';

/// Full project CRUD + metadata template management.
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
        ],
      ),
      body: Stack(
        children: [
          Obx(() {
            final visible = c.projects;
            return ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              children: [
                ...visible.map((p) => _projectTile(context, c, p)),
                if (visible.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No projects yet. Tap "New Project".'),
                    ),
                  ),
              ],
            );
          }),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              heroTag: 'projectsFab',
              onPressed: () => _showProjectDialog(context, c),
              icon: const Icon(Icons.add),
              label: const Text('New Project'),
            ),
          ),
        ],
      ),
    );
  }

  /// One project card with its Edit / Edit template / Delete menu.
  Widget _projectTile(BuildContext context, ProjectsController c, Project p) {
    final dateText =
        '${p.startDate.year}-${p.startDate.month.toString().padLeft(2, '0')}-${p.startDate.day.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const CircleAvatar(child: Icon(Icons.folder_special_outlined)),
        title: Text(
          p.name,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'ID: ${p.projectId}'
            '${(p.countryLocationCode ?? '').isNotEmpty ? '  ·  ${p.countryLocationCode}' : ''}'
            '  ·  Start: $dateText',
            style: const TextStyle(fontSize: 14),
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) => _onProjectAction(context, c, p, value),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit…')),
            const PopupMenuItem(
              value: 'template',
              child: Text('Edit template…'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('Delete…')),
          ],
        ),
      ),
    );
  }

  Future<void> _onProjectAction(
    BuildContext context,
    ProjectsController c,
    Project p,
    String action,
  ) async {
    switch (action) {
      case 'edit':
        await _showProjectDialog(context, c, existing: p);
        break;
      case 'template':
        await Get.to(() => TemplateEditorPage(project: p, controller: c));
        break;
      case 'delete':
        await _confirmDelete(context, c, p);
        break;
    }
  }

  // ── Add / edit dialog ─────────────────────────────────────────────────────

  Future<void> _showProjectDialog(
    BuildContext context,
    ProjectsController c, {
    Project? existing,
  }) async {
    final isEdit = existing != null;
    final nameCtl = TextEditingController(text: existing?.name ?? '');
    final idCtl = TextEditingController(text: existing?.projectId ?? '');
    final codeCtl = TextEditingController(
      text: existing?.countryLocationCode ?? '',
    );
    DateTime? startDate = existing?.startDate ?? DateTime.now();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) {
            final dateText = startDate == null
                ? 'Select a date'
                : '${startDate!.year}-${startDate!.month.toString().padLeft(2, '0')}-${startDate!.day.toString().padLeft(2, '0')}';
            return AlertDialog(
              title: Text(isEdit ? 'Edit project' : 'New Project'),
              // AlertDialog otherwise shrink-wraps to the fields' intrinsic
              // width (~280px) — too cramped for real project names/codes.
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: nameCtl,
                        decoration: const InputDecoration(
                          labelText: 'Project Name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: idCtl,
                        decoration: const InputDecoration(
                          labelText: 'Project ID',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: codeCtl,
                        maxLength: 32,
                        decoration: const InputDecoration(
                          labelText: 'Country/Location Code',
                          helperText:
                              'Country + location in one short code, e.g. PH-CEB',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: Text('Start Date: $dateText')),
                          TextButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: ctx,
                                initialDate: startDate ?? DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null) {
                                setState(() => startDate = picked);
                              }
                            },
                            child: const Text('Pick date'),
                          ),
                        ],
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          error!,
                          style: TextStyle(color: Get.theme.colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (nameCtl.text.trim().isEmpty) {
                      setState(() => error = 'Project Name is required.');
                      return;
                    }
                    if (idCtl.text.trim().isEmpty) {
                      setState(() => error = 'Project ID is required.');
                      return;
                    }
                    if (codeCtl.text.trim().isEmpty) {
                      setState(
                        () => error = 'Country/Location Code is required.',
                      );
                      return;
                    }
                    if (startDate == null) {
                      setState(() => error = 'Pick a start date.');
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: Text(isEdit ? 'Save' : 'Create'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;
    try {
      if (isEdit) {
        await c.updateProject(
          key: existing.key,
          name: nameCtl.text.trim(),
          projectId: idCtl.text.trim(),
          countryLocationCode: codeCtl.text.trim(),
          startDate: startDate,
        );
        showAppSnackBar(
          'Saved',
          'Updated ${nameCtl.text.trim()}.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
          width: kCompactSnackBarWidth,
        );
      } else {
        final created = await c.createProject(
          name: nameCtl.text.trim(),
          projectId: idCtl.text.trim(),
          countryLocationCode: codeCtl.text.trim(),
          startDate: startDate!,
        );
        showAppSnackBar(
          'Project created',
          '${nameCtl.text.trim()} is ready for assignment.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
          width: kCompactSnackBarWidth,
        );
        await Get.to(() => TemplateEditorPage(project: created, controller: c));
      }
    } catch (e) {
      showAppSnackBar(
        'Error',
        '$e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
        width: kCompactSnackBarWidth,
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ProjectsController c,
    Project p,
  ) async {
    final assignedCount = c.assignedUserCount(p);
    final needsStrongConfirm = p.hasData || assignedCount > 0;

    if (!needsStrongConfirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete project'),
          content: Text(
            'This permanently deletes "${p.name}" (${p.projectId}).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      final ctl = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          String? error;
          return StatefulBuilder(
            builder: (ctx, setState) => AlertDialog(
              title: const Text('Delete project'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This project ${p.hasData ? 'has capture data recorded on operator PCs' : 'may have data on operator PCs (not checkable from here)'} '
                    'and $assignedCount assigned user(s). Deleting it unassigns those users; '
                    'groups already stamped with it keep their data locally. Type the Project ID to confirm.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctl,
                    decoration: const InputDecoration(labelText: 'Project ID'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(color: Get.theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  ),
                  onPressed: () {
                    if (ctl.text.trim().toLowerCase() !=
                        p.projectId.toLowerCase()) {
                      setState(() => error = 'Project ID does not match.');
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
        },
      );
      if (confirmed != true) return;
    }

    try {
      await c.deleteProject(p.key);
      showAppSnackBar(
        'Deleted',
        '"${p.name}" removed.',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
        colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
        width: kCompactSnackBarWidth,
      );
    } catch (e) {
      showAppSnackBar(
        'Error',
        '$e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
        width: kCompactSnackBarWidth,
      );
    }
  }
}
