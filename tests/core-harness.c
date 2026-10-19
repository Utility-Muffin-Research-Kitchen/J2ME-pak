/*
 * Off-device check of core/leaf.patch.
 *
 * Loads the packaged core the way a libretro frontend does, answers just
 * enough of the environment for retro_init() to start the JVM, and reports
 * what it started. tests/smoke-core.sh drives it and asserts on the output.
 *
 *   core-harness <core.so> <system_dir> init   start, describe the JVM, deinit
 *   core-harness <core.so> <system_dir> hold   start, describe, then wait to be killed
 *   core-harness <core.so> <system_dir> load   start, describe, then try retro_load_game()
 *   core-harness <core.so> <system_dir> load <game>
 *                                              the same with that game, then wait to be killed
 *   core-harness <core.so> <system_dir> run <game> <frames> <rrggbb>
 *                                              load the game and run it until that many frames
 *                                              have followed the first one entirely that colour
 *                                              (or for 300 s), counting those that are not
 *
 * Output lines are "key=value". Nothing here is shipped.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "libretro.h"

static const char *system_dir;
static char save_dir[4096];

/* run mode: frames checked against one expected colour */
static uint32_t expected_rgb;
static long frames_seen, frames_good, frames_bad, first_good = -1;
static unsigned last_width, last_height;
static uint32_t last_corner, last_centre;

static void core_log(enum retro_log_level level, const char *fmt, ...)
{
	va_list args;
	(void)level;
	fputs("core: ", stderr);
	va_start(args, fmt);
	vfprintf(stderr, fmt, args);
	va_end(args);
}

/* retro_run() switches rumble off every frame without checking that the
   frontend gave it an interface; RetroArch always does. */
static bool set_rumble_state(unsigned port, enum retro_rumble_effect effect, uint16_t strength)
{
	(void)port; (void)effect; (void)strength;
	return true;
}

static bool environment(unsigned cmd, void *data)
{
	switch (cmd)
	{
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
		((struct retro_log_callback *)data)->log = core_log;
		return true;
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
		*(const char **)data = system_dir;
		return true;
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
		*(const char **)data = save_dir;
		return true;
	case RETRO_ENVIRONMENT_GET_VARIABLE:
	{
		struct retro_variable *var = data;
		if (strcmp(var->key, "freej2me_resolution") == 0)
		{
			var->value = "240x320";
			return true;
		}
		/* The option's default, which a frontend passes in. Unanswered, the
		   core keeps upstream's Green, which tints every pixel. */
		if (strcmp(var->key, "freej2me_backlightcolor") == 0)
		{
			var->value = "Disabled";
			return true;
		}
		return false;
	}
	case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
		((struct retro_rumble_interface *)data)->set_rumble_state = set_rumble_state;
		return true;
	case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
		printf("message=%s\n", ((const struct retro_message_ext *)data)->msg);
		fflush(stdout);
		return true;
	case RETRO_ENVIRONMENT_SET_VARIABLES:
	case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
	case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
	case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
		return true;
	default:
		return false;
	}
}

/* Every frame after the first that is entirely the expected colour has to
   be entirely that colour too: the test MIDlet paints nothing else. */
static void video(const void *data, unsigned width, unsigned height, size_t pitch)
{
	const unsigned char *row = data;
	bool good = data != NULL && width > 0 && height > 0;
	unsigned x, y;

	frames_seen++;
	if (good)
	{
		last_width = width;
		last_height = height;
		last_corner = *(const uint32_t *)data & 0xFFFFFF;
		last_centre = ((const uint32_t *)(row + (height / 2) * pitch))[width / 2] & 0xFFFFFF;
	}
	for (y = 0; good && y < height; y++, row += pitch)
	{
		const uint32_t *px = (const uint32_t *)row;
		for (x = 0; x < width; x++)
		{
			if ((px[x] & 0xFFFFFF) != expected_rgb) { good = false; break; }
		}
	}
	if (good)
	{
		frames_good++;
		if (first_good < 0) { first_good = frames_seen; }
	}
	else if (first_good >= 0) { frames_bad++; }
}

static void input_poll(void) { }
static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
	(void)port; (void)device; (void)index; (void)id;
	return 0;
}
static void audio_sample(int16_t left, int16_t right) { (void)left; (void)right; }
static size_t audio_sample_batch(const int16_t *data, size_t frames) { (void)data; return frames; }

/* The only child of this process, or 0. */
static pid_t child_pid(void)
{
	DIR *proc = opendir("/proc");
	struct dirent *entry;
	pid_t found = 0;
	while (proc && (entry = readdir(proc)))
	{
		char path[300], buf[512];
		FILE *fp;
		char *close_paren;
		int ppid = 0;
		if (entry->d_name[0] < '0' || entry->d_name[0] > '9') { continue; }
		snprintf(path, sizeof(path), "/proc/%s/stat", entry->d_name);
		if (!(fp = fopen(path, "r"))) { continue; }
		if (fgets(buf, sizeof(buf), fp) && (close_paren = strrchr(buf, ')')))
		{
			char state;
			if (sscanf(close_paren + 1, " %c %d", &state, &ppid) == 2 && ppid == getpid() && state != 'Z')
			{
				found = (pid_t)atoi(entry->d_name);
			}
		}
		fclose(fp);
	}
	if (proc) { closedir(proc); }
	return found;
}

/* Print a NUL-separated /proc file as one key=value line per entry. */
static void print_nul_list(pid_t pid, const char *file, const char *key, const char *only_prefix)
{
	char path[64], buf[65536];
	size_t len, i = 0;
	FILE *fp;
	snprintf(path, sizeof(path), "/proc/%d/%s", (int)pid, file);
	if (!(fp = fopen(path, "r"))) { return; }
	len = fread(buf, 1, sizeof(buf) - 1, fp);
	fclose(fp);
	buf[len] = '\0';
	while (i < len)
	{
		const char *item = buf + i;
		if (!only_prefix || strncmp(item, only_prefix, strlen(only_prefix)) == 0)
		{
			printf("%s=%s\n", key, item);
		}
		i += strlen(item) + 1;
	}
}

int main(int argc, char **argv)
{
	void *core;
	void (*set_environment)(retro_environment_t);
	void (*init)(void);
	void (*deinit)(void);
	bool (*load_game)(const struct retro_game_info *);
	pid_t java;
	char cwd[4096];
	char link[64];
	ssize_t n;

	if (argc != 4 && !(argc == 5 && strcmp(argv[3], "load") == 0) &&
	    !(argc == 7 && strcmp(argv[3], "run") == 0))
	{
		fprintf(stderr, "usage: %s <core.so> <system_dir> init|hold|load [game]\n"
			"       %s <core.so> <system_dir> run <game> <frames> <rrggbb>\n", argv[0], argv[0]);
		return 2;
	}
	system_dir = argv[2];
	snprintf(save_dir, sizeof(save_dir), "%s/saves", system_dir);

	if (!(core = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL))) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
	set_environment = (void (*)(retro_environment_t))dlsym(core, "retro_set_environment");
	init = (void (*)(void))dlsym(core, "retro_init");
	deinit = (void (*)(void))dlsym(core, "retro_deinit");
	load_game = (bool (*)(const struct retro_game_info *))dlsym(core, "retro_load_game");
	if (!set_environment || !init || !deinit || !load_game) { fprintf(stderr, "missing libretro symbols\n"); return 2; }

	set_environment(environment);
	init();

	/* A child that failed to exec and fell back into this code would run
	   on from here too, but with stdout on the frame pipe: the parent reads
	   its output as the JVM's handshake and reports it as java_pid. Upstream
	   does exactly that; the smoke test's java_pid=0 check catches it. */
	printf("after_init=%d\n", (int)getpid());
	fflush(stdout);

	java = child_pid();
	printf("java_pid=%d\n", (int)java);
	if (java)
	{
		print_nul_list(java, "cmdline", "java_arg", NULL);
		print_nul_list(java, "environ", "java_env", "LD_LIBRARY_PATH=");
		print_nul_list(java, "environ", "java_env", "LOCPATH=");
		print_nul_list(java, "environ", "java_env", "LC_ALL=");
		snprintf(link, sizeof(link), "/proc/%d/cwd", (int)java);
		if ((n = readlink(link, cwd, sizeof(cwd) - 1)) > 0) { cwd[n] = '\0'; printf("java_cwd=%s\n", cwd); }
	}
	fflush(stdout);

	if (strcmp(argv[3], "hold") == 0)
	{
		printf("holding=1\n");
		fflush(stdout);
		for (;;) { pause(); }
	}

	if (strcmp(argv[3], "load") == 0)
	{
		/* Without a game only the failure path is meaningful: with no JVM
		   running the core must refuse it instead of running on without one.
		   With one, the JVM opens it while this waits; the caller reads
		   FreeJ2ME's log, then kills this process and the JVM with it. */
		struct retro_game_info info = { argc == 5 ? argv[4] : "/tmp/harness-game.jar", NULL, 0, NULL };
		printf("load_game=%d\n", load_game(&info) ? 1 : 0);
		fflush(stdout);
		if (argc == 5)
		{
			printf("holding=1\n");
			fflush(stdout);
			for (;;) { pause(); }
		}
	}

	if (strcmp(argv[3], "run") == 0)
	{
		/* A frontend's loop, minus the frontend: every retro_run() requests
		   one frame from the JVM and hands it to video(). */
		struct retro_game_info info = { argv[4], NULL, 0, NULL };
		void (*run)(void) = (void (*)(void))dlsym(core, "retro_run");
		void (*set_video)(retro_video_refresh_t) = (void (*)(retro_video_refresh_t))dlsym(core, "retro_set_video_refresh");
		void (*set_poll)(retro_input_poll_t) = (void (*)(retro_input_poll_t))dlsym(core, "retro_set_input_poll");
		void (*set_state)(retro_input_state_t) = (void (*)(retro_input_state_t))dlsym(core, "retro_set_input_state");
		void (*set_audio)(retro_audio_sample_t) = (void (*)(retro_audio_sample_t))dlsym(core, "retro_set_audio_sample");
		void (*set_batch)(retro_audio_sample_batch_t) = (void (*)(retro_audio_sample_batch_t))dlsym(core, "retro_set_audio_sample_batch");
		long frames = atol(argv[5]);
		time_t give_up = time(NULL) + 300;

		if (!run || !set_video || !set_poll || !set_state || !set_audio || !set_batch)
		{
			fprintf(stderr, "missing libretro symbols\n");
			return 2;
		}
		expected_rgb = (uint32_t)strtoul(argv[6], NULL, 16) & 0xFFFFFF;
		set_video(video);
		set_poll(input_poll);
		set_state(input_state);
		set_audio(audio_sample);
		set_batch(audio_sample_batch);
		printf("load_game=%d\n", load_game(&info) ? 1 : 0);
		fflush(stdout);
		/* The JVM answers every request at once, with a blank frame until the
		   MIDlet has painted, so count from the first good frame: under
		   emulation that can take many frames. */
		while ((first_good < 0 || frames_seen - first_good < frames) && time(NULL) < give_up) { run(); }
		printf("frames_seen=%ld\nfirst_good=%ld\nframes_good=%ld\nframes_bad=%ld\n",
			frames_seen, first_good, frames_good, frames_bad);
		printf("last_frame=%ux%u corner=%06x centre=%06x\n", last_width, last_height,
			(unsigned)last_corner, (unsigned)last_centre);
		fflush(stdout);
	}

	deinit();
	if (java)
	{
		printf("java_after_deinit=%s\n", kill(java, 0) == 0 ? "alive" : (errno == ESRCH ? "gone" : "unknown"));
	}
	fflush(stdout);
	return 0;
}
