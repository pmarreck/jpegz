import java.io.ByteArrayOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;

public class AcBoundaryProbe {
	static void append(ByteArrayOutputStream out, int... values) {
		for (int value : values) out.write(value);
	}
	static byte[] fixture(int precision, int size, int... payload) {
		var out = new ByteArrayOutputStream();
		append(out, 255, 216, 255, 219, 0, 67, 0);
		for (int i = 0; i < 64; i++) out.write(1);
		append(out, 255, 194, 0, 11, precision, 0, 8, 0, 8, 1, 1, 17, 0);
		append(out, 255, 196, 0, 20, 0, 1);
		for (int i = 0; i < 15; i++) out.write(0);
		append(out, 0, 255, 196, 0, 21, 16, 1, 1);
		for (int i = 0; i < 14; i++) out.write(0);
		append(out, 0, size, 255, 218, 0, 8, 1, 1, 0, 0, 0, 0, 127,
			255, 218, 0, 8, 1, 1, 0, 1, 63, 0);
		append(out, payload);
		append(out, 255, 217);
		return out.toByteArray();
	}
	static void compare(String name, byte[] bytes, String binary, Path directory) throws Exception {
		PriorArtProbe.run(name, bytes);
		Path path = directory.resolve(name + ".jpg");
		Files.write(path, bytes, java.nio.file.StandardOpenOption.CREATE_NEW);
		Process process = new ProcessBuilder(binary, "--json", path.toString()).redirectErrorStream(true).start();
		String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
		int exit = process.waitFor();
		System.out.printf("jpegz\t%s\texit=%d\t%s%n", name, exit, output.strip());
	}
	public static void main(String[] args) throws Exception {
		Path directory = Path.of(args[1]);
		Files.createDirectories(directory);
		compare("ac-p8-size10-valid", fixture(8, 10, 160, 7), args[0], directory);
		compare("ac-p8-size11-invalid", fixture(8, 11, 160, 3), args[0], directory);
		compare("ac-p12-size14-valid", fixture(12, 14, 160, 0, 127), args[0], directory);
		compare("ac-p12-size15-invalid", fixture(12, 15, 160, 0, 63), args[0], directory);
	}
}
