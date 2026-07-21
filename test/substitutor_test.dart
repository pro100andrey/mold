import 'package:mold/mold.dart';
import 'package:test/test.dart';

void main() {
  group('Substitutor', () {
    const converter = CaseConverter();

    Substitutor forRename(String from, String to) =>
        Substitutor(converter.replacements(from, to));

    test('rewrites all four casings in text content', () {
      final s = forRename('super_server', 'my_project');
      const input = 'super_server SuperServer super-server SUPER_SERVER';
      expect(s.apply(input), 'my_project MyProject my-project MY_PROJECT');
    });

    test('rewrites path segments', () {
      final s = forRename('super_server', 'my_project');
      expect(
        s.apply('lib/super_server/SuperServer.dart'),
        'lib/my_project/MyProject.dart',
      );
    });

    test('does not cascade a substituted value back through the table', () {
      // server→client and client→server in one table: a single pass swaps
      // them rather than turning both into one value.
      final s = Substitutor({'server': 'client', 'client': 'server'});
      expect(s.apply('server client'), 'client server');
    });

    test('prefers the longest token at overlapping positions', () {
      final s = Substitutor({'super_server': 'X', 'server': 'Y'});
      expect(s.apply('super_server'), 'X');
      expect(s.apply('a server here'), 'a Y here');
    });

    test('an empty table is identity', () {
      expect(Substitutor(const {}).apply('untouched'), 'untouched');
    });
  });
}
