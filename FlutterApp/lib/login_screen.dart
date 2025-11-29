import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'signup_screen.dart';

const Set<String> allowedEmails = {
  'nguyenhoangphuctr@gmail.com',
  // 'phucnghoang112233@gmail.com',
};

class LoginScreen extends StatefulWidget {
  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  bool _isLoading = false;
  bool _isGoogleLoading = false;
  bool _isResetting = false; // <-- thêm

  bool _obscurePassword = true;

  Future<bool> _enforceGoogleAllowlist() async {
    final email = _auth.currentUser?.email?.toLowerCase() ?? '';
    if (!allowedEmails.contains(email)) {
      // sign out cả Firebase lẫn Google để đóng phiên ngay lập tức
      await _auth.signOut();
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
      _showErrorSnackBar('Email không nằm trong danh sách cho phép.');
      return false;
    }
    return true;
  }

  // --- Đăng nhập Email/Password ---
  void _loginWithEmailAndPassword() async {
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      _showErrorSnackBar('Vui lòng nhập email và mật khẩu.');
      return;
    }
    setState(() => _isLoading = true);

    try {
      await _auth.signInWithEmailAndPassword(
        email: _usernameController.text.trim(),
        password: _passwordController.text.trim(),
      );
      _navigateToHome();
    } on FirebaseAuthException catch (e) {
      String message;
      if (e.code == 'user-not-found') {
        message = 'Không tìm thấy người dùng với email này.';
      } else if (e.code == 'wrong-password') {
        message = 'Mật khẩu không đúng.';
      } else if (e.code == 'invalid-email') {
        message = 'Định dạng email không hợp lệ.';
      } else if (e.code == 'user-disabled') {
        message = 'Tài khoản này đã bị vô hiệu hóa.';
      } else {
        message = 'Đăng nhập thất bại: ${e.message}';
      }
      _showErrorSnackBar(message);
    } catch (e) {
      _showErrorSnackBar('Đã xảy ra lỗi không xác định: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- Đăng nhập Google ---
  Future<void> _signInWithGoogle() async {
    setState(() => _isGoogleLoading = true);
    try {
      await _googleSignIn.signOut(); // đảm bảo mỗi lần là phiên mới
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        setState(() => _isGoogleLoading = false);
        return; // user hủy
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await _auth.signInWithCredential(credential);

      // NEW: enforce allowlist
      final ok = await _enforceGoogleAllowlist();
      if (!ok) {
        // đã signOut và báo lỗi trong _enforceGoogleAllowlist
        return;
      }

      _navigateToHome();
    } on FirebaseAuthException catch (e) {
      _showErrorSnackBar('Lỗi đăng nhập Google với Firebase: ${e.message}');
    } catch (e) {
      _showErrorSnackBar('Đăng nhập bằng Google thất bại: $e');
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  // --- Quên mật khẩu (Email/Password) ---
  Future<void> _handleForgotPassword() async {
    String email = _usernameController.text.trim();
    if (email.isEmpty) {
      final input = await _askEmailDialog();
      if (input == null || input.isEmpty) return;
      email = input.trim();
    }

    setState(() => _isResetting = true);
    try {
      await _auth.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nếu email tồn tại trong hệ thống, một liên kết đặt lại mật khẩu đã được gửi đến $email.\n'
            'Nếu bạn đăng nhập bằng Google, vui lòng khôi phục mật khẩu trên trang của Google.',
          ),
          backgroundColor: Colors.green[700],
          duration: Duration(seconds: 5),
        ),
      );
    } on FirebaseAuthException catch (e) {
      String msg;
      switch (e.code) {
        case 'invalid-email':
          msg = 'Định dạng email không hợp lệ.';
          break;
        case 'user-not-found':
          msg = 'Không tìm thấy người dùng với email này.';
          break;
        default:
          msg = 'Không thể gửi email đặt lại mật khẩu: ${e.message}';
      }
      _showErrorSnackBar(msg);
    } catch (e) {
      _showErrorSnackBar('Có lỗi xảy ra: $e');
    } finally {
      if (mounted) setState(() => _isResetting = false);
    }
  }

  Future<String?> _askEmailDialog() async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Quên mật khẩu'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(hintText: 'Nhập email của bạn'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: Text('Tiếp tục'),
          ),
        ],
      ),
    );
  }

  void _navigateToHome() {
    if (Navigator.of(context).canPop()) {
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      // có thể thay bằng pushNamed nếu muốn
      Navigator.pushReplacementNamed(context, '/home');
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red[600],
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset('assets/logo1.webp', width: 150, height: 150),
                  SizedBox(height: 16),
                  Text(
                    'Smart Agriculture',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Colors.blue[900],
                      letterSpacing: 1.1,
                    ),
                  ),
                  SizedBox(height: 30),

                  // Email
                  TextField(
                    controller: _usernameController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.grey[100],
                      hintText: 'Tài khoản',
                      prefixIcon: Icon(
                        Icons.account_box_outlined,
                        color: Colors.blue[700],
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12.0),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        vertical: 16.0,
                        horizontal: 16.0,
                      ),
                    ),
                    style: TextStyle(color: Colors.grey[900], fontSize: 16),
                  ),
                  SizedBox(height: 16),

                  // Password
                  TextField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.grey[100],
                      hintText: 'Mật khẩu',
                      prefixIcon: Icon(
                        Icons.lock_outline,
                        color: Colors.blue[700],
                      ),
                      // THÊM: icon con mắt
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: Colors.grey[600],
                          size: 20,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12.0),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        vertical: 16.0,
                        horizontal: 16.0,
                      ),
                    ),
                    obscureText: _obscurePassword, // <-- dùng biến thay vì true
                    style: TextStyle(color: Colors.grey[900], fontSize: 16),
                  ),

                  SizedBox(height: 24),

                  _isLoading
                      ? CircularProgressIndicator(color: Colors.blue[700])
                      : ElevatedButton(
                          onPressed: _loginWithEmailAndPassword,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue[700],
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(
                              horizontal: 40,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.0),
                            ),
                            elevation: 3,
                            shadowColor: Colors.blue[900]!.withOpacity(0.2),
                            minimumSize: Size(double.infinity, 50),
                          ),
                          child: Text(
                            'Đăng nhập',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                  SizedBox(height: 16),

                  // Dải phân cách "HOẶC"
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Divider(thickness: 0.8, color: Colors.grey[400]),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10.0),
                        child: Text(
                          'HOẶC',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Divider(thickness: 0.8, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),

                  // Nút Google
                  _isGoogleLoading
                      ? CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.redAccent,
                          ),
                        )
                      : ElevatedButton.icon(
                          icon: Image.asset(
                            'assets/google_logo1.webp',
                            height: 25.0,
                          ),
                          label: Text(
                            'Đăng nhập với Google',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey[800],
                            ),
                          ),
                          onPressed: _signInWithGoogle,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.grey[800],
                            padding: EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.0),
                              side: BorderSide(
                                color: Colors.grey[300]!,
                                width: 1.5,
                              ),
                            ),
                            elevation: 2,
                            shadowColor: Colors.grey.withOpacity(0.2),
                            minimumSize: Size(double.infinity, 50),
                          ),
                        ),
                  SizedBox(height: 20),

                  // Đăng ký & Quên mật khẩu
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => SignUpScreen()),
                          );
                        },
                        child: Text(
                          'Tạo tài khoản mới',
                          style: TextStyle(
                            fontSize: 15,
                            color: Colors.blue[800],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isResetting ? null : _handleForgotPassword,
                        // <-- gọi flow quên mật khẩu
                        child: _isResetting
                            ? SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                'Quên mật khẩu?',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: Colors.grey[700],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
