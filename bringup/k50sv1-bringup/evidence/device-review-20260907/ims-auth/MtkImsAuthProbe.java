import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;

public final class MtkImsAuthProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1 || !(args[0].equals("phone") || args[0].equals("legacy") || args[0].equals("deny")))
            throw new IllegalArgumentException("phone|legacy|deny");
        boolean deny = args[0].equals("deny");
        int uid = Process.myUid();
        if ((args[0].equals("phone") && uid != 1001) ||
            (!args[0].equals("phone") && uid < 10000))
            throw new IllegalStateException("Unexpected test UID " + uid);
        IBinder service = (IBinder) Class.forName("android.os.ServiceManager")
            .getMethod("getService", String.class).invoke(null, "mtkIms");
        if (service == null) throw new IllegalStateException("mtkIms lookup returned null");
        System.out.println("uid=" + uid + " expectation=" + args[0]);
        Parcel query = Parcel.obtain(), descriptor = Parcel.obtain();
        try {
            if (!service.transact(IBinder.INTERFACE_TRANSACTION, query, descriptor, 0) ||
                !"com.mediatek.ims.internal.IMtkImsService".equals(descriptor.readString()))
                throw new IllegalStateException("Descriptor query failed");
            System.out.println("PASS INTERFACE_TRANSACTION");
        } finally { query.recycle(); descriptor.recycle(); }
        for (int code : new int[] {4, 9}) {
            Parcel data = Parcel.obtain(), reply = Parcel.obtain();
            try {
                data.writeInterfaceToken("com.mediatek.ims.internal.IMtkImsService");
                data.writeInt(code == 4 ? 0 : -1); // State read, or validated invalid-phone no-op.
                if (!service.transact(code, data, reply, 0))
                    throw new IllegalStateException("Unknown transaction " + code);
                boolean rejected = false;
                int value = -999;
                try { reply.readException(); if (code == 4) value = reply.readInt(); }
                catch (SecurityException expected) { rejected = true; }
                if (rejected != deny)
                    throw new IllegalStateException("Wrong authorization result for code " + code);
                System.out.println("PASS code=" + code + " denied=" + rejected +
                                   (rejected || code != 4 ? "" : " value=" + value));
            } finally { data.recycle(); reply.recycle(); }
        }
    }
}
