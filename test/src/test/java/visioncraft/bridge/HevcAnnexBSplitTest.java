package visioncraft.bridge;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Mirrors {@code AlvrServerCoordinator.splitHEVCParameterSets} for regression coverage on Linux CI.
 */
class HevcAnnexBSplitTest {

    @Test
    void splitsVpsSpsPpsFromIdrAccessUnit() {
        byte[] vps = nal(32, 1, 2, 3);
        byte[] sps = nal(33, 4, 5);
        byte[] pps = nal(34, 6);
        byte[] idr = nal(19, 7, 8, 9);
        byte[] accessUnit = concat(vps, sps, pps, idr);

        Split split = splitHevcParameterSets(accessUnit);
        assertEquals(3, countStartCodes(split.config));
        assertEquals(1, countStartCodes(split.payload));
        assertTrue(split.config.length > split.payload.length / 2);
        assertArrayEquals(accessUnit, concat(split.config, split.payload));
    }

    @Test
    void nonParameterNalsStayInPayload() {
        byte[] sei = nal(39, 1);
        byte[] idr = nal(20, 2);
        byte[] accessUnit = concat(sei, idr);
        Split split = splitHevcParameterSets(accessUnit);
        assertEquals(0, countStartCodes(split.config));
        assertEquals(2, countStartCodes(split.payload));
    }

    private static byte[] nal(int type, int... payload) {
        byte header = (byte) ((type & 0x3f) << 1);
        byte[] body = new byte[1 + payload.length];
        body[0] = header;
        for (int i = 0; i < payload.length; i++) {
            body[i + 1] = (byte) payload[i];
        }
        return withStartCode(body);
    }

    private static byte[] withStartCode(byte[] nal) {
        byte[] out = new byte[4 + nal.length];
        out[0] = 0;
        out[1] = 0;
        out[2] = 0;
        out[3] = 1;
        System.arraycopy(nal, 0, out, 4, nal.length);
        return out;
    }

    private static byte[] concat(byte[]... parts) {
        int len = 0;
        for (byte[] p : parts) {
            len += p.length;
        }
        byte[] out = new byte[len];
        int at = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, at, p.length);
            at += p.length;
        }
        return out;
    }

    private static int countStartCodes(byte[] data) {
        int count = 0;
        for (int i = 0; i + 3 < data.length; i++) {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
                count++;
            }
        }
        return count;
    }

    private record Split(byte[] config, byte[] payload) {}

    private static Split splitHevcParameterSets(byte[] accessUnit) {
        List<int[]> nals = annexBNalRanges(accessUnit);
        if (nals.isEmpty()) {
            return new Split(new byte[0], accessUnit);
        }
        byte[] startCode = new byte[]{0, 0, 0, 1};
        List<Byte> config = new ArrayList<>();
        List<Byte> payload = new ArrayList<>();
        for (int[] range : nals) {
            int type = (accessUnit[range[0]] >> 1) & 0x3f;
            List<Byte> target = (type == 32 || type == 33 || type == 34) ? config : payload;
            for (byte b : startCode) {
                target.add(b);
            }
            for (int i = range[0]; i < range[1]; i++) {
                target.add(accessUnit[i]);
            }
        }
        return new Split(toArray(config), toArray(payload));
    }

    private static List<int[]> annexBNalRanges(byte[] bytes) {
        List<Integer> prefixStarts = new ArrayList<>();
        List<Integer> payloadStarts = new ArrayList<>();
        int i = 0;
        while (i + 3 < bytes.length) {
            if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1) {
                prefixStarts.add(i);
                payloadStarts.add(i + 3);
                i += 3;
            } else if (i + 4 < bytes.length
                && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1) {
                prefixStarts.add(i);
                payloadStarts.add(i + 4);
                i += 4;
            } else {
                i++;
            }
        }
        List<int[]> ranges = new ArrayList<>();
        for (int index = 0; index < payloadStarts.size(); index++) {
            int start = payloadStarts.get(index);
            int end = index + 1 < prefixStarts.size() ? prefixStarts.get(index + 1) : bytes.length;
            if (start < end) {
                ranges.add(new int[]{start, end});
            }
        }
        return ranges;
    }

    private static byte[] toArray(List<Byte> bytes) {
        byte[] out = new byte[bytes.size()];
        for (int i = 0; i < bytes.size(); i++) {
            out[i] = bytes.get(i);
        }
        return out;
    }
}
