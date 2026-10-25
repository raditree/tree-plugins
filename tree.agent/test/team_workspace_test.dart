import 'package:test/test.dart';
import 'ported_core.dart';

/// 团队共享工作目录与有效 SSH 配置（从核心平移的纯函数）。
void main() {
  CoreAgent agent(
    String id, {
    String parent = '',
    String teamId = '',
    String workspaceDir = '',
    SshConfig? ssh,
  }) => CoreAgent(
    id: id,
    name: id,
    createdAt: 1,
    updatedAt: 1,
    parentAgentId: parent,
    teamId: teamId,
    workspaceDir: workspaceDir,
    sshConfig: ssh,
  );

  test('TOP 解析到自己；成员（含多级）一路向上落到 TOP', () {
    final CoreAgent top = agent('top', workspaceDir: '/proj');
    final CoreAgent mid = agent('mid', parent: 'top', teamId: 'top');
    final CoreAgent leaf = agent('leaf', parent: 'mid', teamId: 'top');
    final Map<String, CoreAgent> byId = <String, CoreAgent>{
      for (final CoreAgent a in <CoreAgent>[top, mid, leaf]) a.id: a,
    };
    CoreAgent? lookup(String id) => byId[id];

    final TeamWorkspace self = teamWorkspaceFor(top, lookup);
    expect(self.owner.id, 'top');
    expect(self.configuredDir, '/proj');

    expect(teamWorkspaceFor(mid, lookup).owner.id, 'top');
    expect(teamWorkspaceFor(leaf, lookup).owner.id, 'top');
    expect(teamWorkspaceFor(leaf, lookup).configuredDir, '/proj');
  });

  test('上级不存在 / 配置成环：以当前层为准，不死循环也不抛', () {
    final CoreAgent orphan = agent('orphan', parent: 'ghost');
    expect(
      teamWorkspaceFor(orphan, (String id) => id == 'orphan' ? orphan : null)
          .owner
          .id,
      'orphan',
    );

    final CoreAgent a = agent('a', parent: 'b');
    final CoreAgent b = agent('b', parent: 'a');
    final Map<String, CoreAgent> byId = <String, CoreAgent>{'a': a, 'b': b};
    expect(teamWorkspaceFor(a, (String id) => byId[id]).owner.id, isIn(<String>['a', 'b']));
  });

  test('有效 SSH：自己配了用自己的；没配跟随 TOP；都没有为 null', () {
    const SshConfig topSsh = SshConfig(host: '10.0.0.1', username: 'open');
    const SshConfig ownSsh = SshConfig(host: '10.0.0.2', username: 'me');
    final CoreAgent top = agent('top', ssh: topSsh);
    final CoreAgent member = agent('m', parent: 'top', ssh: ownSsh);
    final CoreAgent inherit = agent('m2', parent: 'top');
    final CoreAgent none = agent('n');
    final Map<String, CoreAgent> byId = <String, CoreAgent>{
      for (final CoreAgent a in <CoreAgent>[top, member, inherit, none]) a.id: a,
    };
    CoreAgent? lookup(String id) => byId[id];

    expect(teamSshConfigFor(member, lookup)?.host, '10.0.0.2');
    expect(teamSshConfigFor(inherit, lookup)?.host, '10.0.0.1');
    expect(teamSshConfigFor(none, lookup), isNull);
  });
}
