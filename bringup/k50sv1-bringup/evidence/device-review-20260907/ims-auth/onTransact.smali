.method public onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z
    .registers 8
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Landroid/os/RemoteException;
        }
    .end annotation

    packed-switch p1, :pswitch_data_16

    goto :goto_10

    :pswitch_4
    const-string v1, "android.permission.READ_PRIVILEGED_PHONE_STATE"

    goto :goto_9

    :pswitch_7
    const-string v1, "android.permission.MODIFY_PHONE_STATE"

    :goto_9
    iget-object v0, p0, Lcom/mediatek/ims/MtkImsService;->mContext:Landroid/content/Context;

    const-string v2, "MtkImsService"

    invoke-virtual {v0, v1, v2}, Landroid/content/Context;->enforceCallingOrSelfPermission(Ljava/lang/String;Ljava/lang/String;)V

    :goto_10
    invoke-super {p0, p1, p2, p3, p4}, Lcom/mediatek/ims/internal/IMtkImsService$Stub;->onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z

    move-result v0

    return v0

    nop

    :pswitch_data_16
    .packed-switch 0x1
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_4
        :pswitch_4
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_4
        :pswitch_4
        :pswitch_4
        :pswitch_7
        :pswitch_7
        :pswitch_4
        :pswitch_4
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_7
        :pswitch_7
    .end packed-switch
.end method
