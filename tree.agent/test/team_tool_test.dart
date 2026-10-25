import 'package:test/test.dart';
import 'ported_core.dart';

/// team 工具声明（模型面）与核心一致；行为由 team_service_test 覆盖。
void main() {
  test('spec：名字 / 动作枚举 / 参数白名单', () {
    final ToolSpec spec = TeamTool.spec();
    expect(spec.name, 'team');
    expect(spec.description, contains('团队协作'));
    final Map<String, dynamic> params = spec.parameters;
    final Map<String, dynamic> props =
        params['properties'] as Map<String, dynamic>;
    expect(params['required'], <String>['action']);
    final Map<String, dynamic> action =
        props['action'] as Map<String, dynamic>;
    expect(action['enum'], TeamService.actions);
    expect(
      props.keys,
      containsAll(<String>[
        'member_name',
        'target_member_id',
        'cascade',
        'role',
        'duty',
        'can_lead_team',
      ]),
    );
    // 模型只能由用户在成员配置页分配：工具声明里不出现 model_id。
    expect(props.containsKey('model_id'), isFalse);
  });
}
