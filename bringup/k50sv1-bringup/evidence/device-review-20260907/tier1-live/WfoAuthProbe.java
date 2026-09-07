import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;

public final class WfoAuthProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !(args[0].equals("phone") || args[0].equals("legacy") || args[0].equals("deny")))
            throw new IllegalArgumentException("phone|legacy|deny");
        boolean deny = args[0].equals("deny");
        int uid = Process.myUid();
        if ((args[0].equals("phone") && uid != 1001) ||
            (!args[0].equals("phone") && uid < 10000))
            throw new IllegalStateException("Unexpected test UID " + uid);
        IBinder service = (IBinder) Class.forName("android.os.ServiceManager")
            .getMethod("getService", String.class).invoke(null, "wfo");
        if (service == null) throw new IllegalStateException("WFO lookup returned null");
        System.out.println("uid=" + uid + " expectation=" + args[0]);
        for (int code : new int[] {3, 12}) {
            Parcel data = Parcel.obtain(), reply = Parcel.obtain();
            try {
                data.writeInterfaceToken("com.mediatek.wfo.IWifiOffloadService");
                if (code == 3) data.writeInt(0); // getRatType(0), read-only
                // Code 12 setWifiOff() is a verified no-op returning false.
                if (!service.transact(code, data, reply, 0))
                    throw new IllegalStateException("Unknown transaction " + code);
                boolean rejected = false;
                int value = -999;
                try { reply.readException(); value = reply.readInt(); }
                catch (SecurityException expected) { rejected = true; }
                if (rejected != deny)
                    throw new IllegalStateException("Wrong authorization result for code " + code);
                if (!rejected && code == 12 && value != 0)
                    throw new IllegalStateException("No-op unexpectedly returned true");
                System.out.println("PASS code=" + code + " denied=" + rejected +
                                   (rejected ? "" : " value=" + value));
            } finally { data.recycle(); reply.recycle(); }
        }
    }
}
