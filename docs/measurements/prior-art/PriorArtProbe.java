import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import io.parsingdata.jpegfragments.validator.InMemoryByteStream;
import io.parsingdata.jpegfragments.validator.jpeg.JpegValidator;

public class PriorArtProbe {
	static void run(String name, byte[] data) throws Exception {
		StringBuilder hash = new StringBuilder();
		for (byte value : MessageDigest.getInstance("SHA-256").digest(data))
			hash.append(String.format("%02x", value));
		try {
			var result = new JpegValidator().validate(new InMemoryByteStream(data));
			System.out.printf("%s\t%d\t%s\t%s\t%s\t%s%n", name, data.length, hash, result.completed, result.offset, result.info);
		} catch (Exception error) {
			System.out.printf("%s\t%d\t%s\tEXCEPTION\t%s\t%s%n", name, data.length, hash, error.getClass().getName(), error.getMessage());
		}
	}
	public static void main(String[] args) throws Exception {
		byte[] original = Files.readAllBytes(Path.of(args[0]));
		if (original.length != 520 || original[441] != (byte)255 || original[442] != (byte)218)
			throw new IllegalArgumentException("Unexpected fixture layout");
		byte[] prefix = Arrays.copyOf(original, 441);
		byte[] closed = Arrays.copyOf(prefix, 443);
		closed[441] = (byte)255;
		closed[442] = (byte)217;
		run("progressive-original", original);
		run("progressive-prefix-eoi", closed);
		run("progressive-prefix-no-eoi", prefix);
		run("progressive-original-no-eoi", Arrays.copyOf(original, 518));
		run("baseline-original", Files.readAllBytes(Path.of(args[1])));
	}
}
