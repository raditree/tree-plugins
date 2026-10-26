/// 委派路由申报（核心 `system.collect.api.routes` → 插件）。
///
/// 13 条 **files 路由**与原核心 `ApiPaths` 同键同形。Git 3 条按用户决定删除，
/// 本插件**不申报**（`/api/workspaces/{id}/git/*`、`/api/files/{id}/git-status`）。
library;

/// 收集站 id：核心请插件申报自己承接的 REST 路由。
const String kApiRoutesStation = 'system.collect.api.routes';

/// `GET` 列目录 / `DELETE` 删除（同一条路径，按方法区分）。
const String filesPattern = '/api/files/{workspaceId}';

/// 读内容 / 写完整文本。
const String fileContentPattern = '/api/files/{workspaceId}/content';

/// PDF 基本信息。
const String filePdfInfoPattern = '/api/files/{workspaceId}/pdf_info';

/// 分片上传三段。
const String fileUploadInitPattern = '/api/files/{workspaceId}/upload_init';
const String fileUploadChunkPattern = '/api/files/{workspaceId}/upload_chunk';
const String fileUploadCompletePattern =
    '/api/files/{workspaceId}/upload_complete';

/// 把工作空间子树复制到本机目录。
const String fileSyncToLocalPattern = '/api/files/{workspaceId}/syncToLocal';

/// 单文件原始字节下载 / 目录打包下载。
const String fileDownloadPattern = '/api/files/{workspaceId}/download';
const String fileDownloadFolderPattern =
    '/api/files/{workspaceId}/download_folder';

/// 结构改动。
const String fileMkdirPattern = '/api/files/{workspaceId}/mkdir';
const String fileRenamePattern = '/api/files/{workspaceId}/rename';

/// 本插件承接的全部文件路由（13 条，不含 Git）。
const List<Map<String, String>> kDeclaredRoutes = <Map<String, String>>[
  <String, String>{'method': 'GET', 'pattern': filesPattern},
  <String, String>{'method': 'DELETE', 'pattern': filesPattern},
  <String, String>{'method': 'GET', 'pattern': fileContentPattern},
  <String, String>{'method': 'PUT', 'pattern': fileContentPattern},
  <String, String>{'method': 'GET', 'pattern': filePdfInfoPattern},
  <String, String>{'method': 'POST', 'pattern': fileUploadInitPattern},
  <String, String>{'method': 'POST', 'pattern': fileUploadChunkPattern},
  <String, String>{'method': 'POST', 'pattern': fileUploadCompletePattern},
  <String, String>{'method': 'POST', 'pattern': fileSyncToLocalPattern},
  <String, String>{'method': 'POST', 'pattern': fileDownloadPattern},
  <String, String>{'method': 'POST', 'pattern': fileDownloadFolderPattern},
  <String, String>{'method': 'POST', 'pattern': fileMkdirPattern},
  <String, String>{'method': 'POST', 'pattern': fileRenamePattern},
];
