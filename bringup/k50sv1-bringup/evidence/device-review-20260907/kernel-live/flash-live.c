#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "kd_flashlight.h"
static int fd=-1;
static void fail(const char *what) { perror(what); if(fd>=0) close(fd); exit(1); }
static void command(unsigned int request,int value) {
    kdStrobeDrvArg arg={e_CAMERA_MAIN_SENSOR,1,value};
    if(ioctl(fd,request,&arg)<0) fail("flash ioctl");
}
static void state(const char *label,int expected) {
    const char *path="/sys/bus/platform/devices/mt-pmic/pmic_access";
    int reg=open(path,O_WRONLY|O_CLOEXEC);
    if(reg<0) fail("PMIC selector open");
    /* Four bytes enter only the driver's register-read branch. */
    if(write(reg,"0326",4)!=4) fail("PMIC selector write");
    close(reg); reg=open(path,O_RDONLY|O_CLOEXEC);
    if(reg<0) fail("PMIC result open");
    char buf[32]={0}; ssize_t len=read(reg,buf,sizeof(buf)-1); close(reg);
    if(len<=0) fail("PMIC result read");
    int value=atoi(buf)&3;
    printf("%s %s ISINK0/1=%d expected=%d\n",value==expected?"PASS":"FAIL",label,value,expected);
    fflush(stdout);
    if(value!=expected) { if(fd>=0)close(fd); exit(1); }
}
static void open_flash(void) {
    fd=open("/dev/kd_camera_flashlight",O_RDWR|O_CLOEXEC);
    if(fd<0)fail("flash open");
    command(FLASH_IOC_GET_PART_ID,0);
    command(FLASHLIGHTIOC_X_SET_DRIVER,0);
}
static void close_flash(void) { if(close(fd)<0)fail("flash close"); fd=-1; }
int main(void) {
    open_flash(); state("initial",0);
    command(FLASH_IOC_SET_TIME_OUT_TIME_MS,300);
    command(FLASH_IOC_SET_ONOFF,1); usleep(100000); state("timed-on",3);
    usleep(400000); state("timer-expired",0);
    command(FLASH_IOC_SET_TIME_OUT_TIME_MS,0);
    command(FLASH_IOC_SET_ONOFF,1); usleep(2000000); state("continuous-torch",3);
    command(FLASH_IOC_SET_ONOFF,0); state("explicit-off",0);
    command(FLASH_IOC_SET_TIME_OUT_TIME_MS,500);
    command(FLASH_IOC_SET_ONOFF,1); usleep(50000); close_flash(); state("release-off",0);
    open_flash(); command(FLASH_IOC_SET_TIME_OUT_TIME_MS,0);
    command(FLASH_IOC_SET_ONOFF,1); usleep(700000); state("reopened-after-old-deadline",3);
    close_flash(); state("final-release-off",0);
    return 0;
}
