// home_screen.dart
import 'package:flutter/material.dart';

import 'login_screen.dart';
import 'node_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Danh sách khu vực (mặc định 2 khu vực)
  final List<Map<String, String>> _nodes = [
    {'name': 'Khu vực 1', 'id': 'N01'},
    {'name': 'Khu vực 2', 'id': 'N02'},
  ];

  final _nameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  void _openAddNodeDialog() {
    _nameCtrl.clear();
    _idCtrl.clear();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Thêm khu vực giám sát'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Tên khu vực'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Vui lòng nhập tên khu vực';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _idCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Mã node'),
                validator: (v) {
                  final value = (v ?? '').trim().toUpperCase();
                  if (value.isEmpty) return 'Vui lòng nhập mã node';
                  final isDup = _nodes.any((e) => e['id'] == value);
                  if (isDup) return 'Mã node đã tồn tại';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              if (_formKey.currentState?.validate() != true) return;
              final name = _nameCtrl.text.trim();
              final id = _idCtrl.text.trim().toUpperCase();

              setState(() {
                _nodes.add({'name': name, 'id': id});
              });

              Navigator.pop(context);
            },
            child: const Text('Thêm'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(Map<String, String> node) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Xóa khu vực'),
            content: Text(
              'Bạn có chắc muốn xóa “${node['name']} (${node['id']})”?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Hủy'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Xóa'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => LoginScreen()),
            );
          },
        ),
        title: const Text(
          'Các khu vực giám sát',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 25,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.blue[800],
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.blue[800]!, Colors.blue[400]!],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: ListView.separated(
          padding: const EdgeInsets.all(16.0),
          itemCount: _nodes.length,
          separatorBuilder: (_, __) => const SizedBox(height: 20),
          itemBuilder: (context, index) {
            final node = _nodes[index];
            final canDelete = index >= 2;
            final id = node['id']!;

            final card = _buildNodeCard(
              context,
              nodeName: node['name']!,
              nodeId: id,
            );

            if (!canDelete) return card;
            return Dismissible(
              key: ValueKey(id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                color: Colors.red.shade400,
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              confirmDismiss: (_) => _confirmDelete(node),
              onDismissed: (_) {
                setState(() => _nodes.removeWhere((e) => e['id'] == id));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Đã xóa ${node['name']}')),
                );
              },
              child: card,
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddNodeDialog,
        tooltip: 'Thêm khu vực',
        child: const Icon(Icons.add),
        backgroundColor: Colors.red[400],
      ),
    );
  }

  Widget _buildNodeCard(
    BuildContext context, {
    required String nodeName,
    required String nodeId,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15.0)),
      color: Colors.white,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 10,
        ),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.settings_input_antenna,
            color: Colors.blue[800],
            size: 28,
          ),
        ),
        title: Text(
          nodeName,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.blue[900]!,
          ),
        ),
        subtitle: Text(
          nodeId,
          style: TextStyle(fontSize: 14, color: Colors.grey[700]),
        ),
        trailing: Icon(Icons.arrow_forward_ios, color: Colors.grey[400]),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  NodeDetailScreen(nodeName: nodeName, nodeId: nodeId),
            ),
          );
        },
      ),
    );
  }
}
