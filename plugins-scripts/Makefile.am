## Process this file with automake to produce Makefile.in

SUFFIXES = .pl .pm .sh

VPATH=$(top_srcdir) $(top_srcdir)/plugins-scripts $(top_srcdir)/plugins-scripts/t

libexec_SCRIPTS=check_db2_health
MY_MODULES=
EXTRA_MODULES=\
  Nagios/DBD/DB2/Server/Instance.pm \
  Nagios/DBD/DB2/Server/Instance/Database.pm \
  Nagios/DBD/DB2/Server/Instance/Database/Tablespace.pm \
  Nagios/DBD/DB2/Server/Instance/Database/Bufferpool.pm \
  Nagios/DBD/DB2/Server/Instance/Database/Partition.pm \
  Nagios/DBD/DB2/Server/Instance/Database/Lock.pm \
  Nagios/DBD/DB2/Server/Instance/Subscriptionset.pm \
  Nagios/DBD/DB2/Server.pm \
  Nagios/Extraopts.pm
EXTRA_DIST=check_db2_health.pl $(EXTRA_MODULES)

CLEANFILES=$(libexec_SCRIPTS)

AM_INSTALL_PROGRAM_FLAGS=@INSTALL_OPTS@

.pm :
	$(AWK) -f ./subst $< > $@
	chmod +x $@

.pl :
	$(AWK) -f ./subst $< > $@
	chmod +x $@

.sh :
	$(AWK) -f ./subst $< > $@
	chmod +x $@

$(libexec_SCRIPTS) : $(EXTRA_DIST)
	$(ECHO) "#! #PERL# -w" | $(AWK) -f ./subst > $@
#since 1.5.1	$(ECHO) "# nagios: -epn" >> $@
	$(ECHO) >> $@
	$(ECHO) "my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );" >> $@
	$(ECHO) "my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );" >> $@
	for m in ${EXTRA_MODULES}; do \
		$(SED) -e 's/^1;//g' < $$m | $(AWK) -f ./subst | $(GREP) -v "my %ERROR" >> $@; \
	done
	if [ -d "${MYMODULES_DIR}" ]; then \
		for m in ${MYMODULES_DIR}/CheckDB2HealthExt*.pm; do \
			if [ -f $$m ]; then \
				$(ECHO) found $$m; \
				$(SED) -e 's/^1;//g' < $$m | $(AWK) -f ./subst | $(GREP) -v "my %ERROR" >> $@; \
			fi \
		done \
	fi
	$(CAT) check_db2_health.pl | $(GREP) -v "^use Nagios" | $(GREP) -v "^my %ERROR" | $(AWK) -f ./subst >> $@
	chmod +x $@
