/// 文件路由的可读失败：状态码 + 机器码 + 可直接展示的中文原因。
///
/// 与核心旧 `FileService` 的口径一致：读路径错误体是 `{detail}`，
/// 写路径（PUT content / mkdir / rename / remove）错误体是
/// `{error, detail}`，冲突还会带当前 `size`。
class FileRouteError implements Exception {
  const FileRouteError(this.status, this.code, this.message, {this.size});

  /// 读路径专用：`code` 与 `message` 同值（旧 `_error(message, status)`）。
  factory FileRouteError.read(String message, [int status = 404]) =>
      FileRouteError(status, message, message);

  final int status;
  final String code;
  final String message;
  final int? size;

  @override
  String toString() => message;
}
