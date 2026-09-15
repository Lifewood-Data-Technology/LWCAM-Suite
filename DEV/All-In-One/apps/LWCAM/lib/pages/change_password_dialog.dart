import 'package:flutter/material.dart';

import '../services/password_hasher.dart';

/// Modal shown when a user must set a new password (first login after
/// creation, or after an admin reset). Returns the new password via
/// Navigator.pop, or null if cancelled. Validates length, confirmation
/// match, and that the new password differs from the temporary one.
class ChangePasswordDialog extends StatefulWidget {
  /// The user's current (temporary) password hash — the new password must
  /// not match it.
  final String currentPasswordHash;

  const ChangePasswordDialog({super.key, required this.currentPasswordHash});

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _obscure = true;

  static const int _minLength = 8;

  @override
  void dispose() {
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final next = _newController.text;
    final confirm = _confirmController.text;
    if (next.length < _minLength) {
      setState(() => _error = 'Password must be at least $_minLength characters.');
      return;
    }
    if (next != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (PasswordHasher.verify(next, widget.currentPasswordHash)) {
      setState(() => _error = 'Choose a password different from the temporary one.');
      return;
    }
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set a new password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You must set a new password before continuing.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newController,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'New password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            obscureText: _obscure,
            decoration: const InputDecoration(labelText: 'Confirm new password'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
