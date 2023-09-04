%let MinSample=50;
%let GoodSample=50;
%let MinRSquare=.1;
%let MaxPValue=.05;
*%let MIDCat=MID15;
%let MIDCat=MID11;
%let maxRstu=2.5;
%let CPOupper1=5000;
%let CPOupper2=1500;
%let CPOlower1=500;
%let CPOlower2=100;
%let nonLuxury=('BUICK','CADILLAC', 'CHEVROLET','CHRYSLER','DODGE','FIAT',
				 'FORD','GMC','HONDA','HYUNDAI','JEEP','KIA','LINCOLN',
				 'MAZDA','MERCURY','MINI','MITSUBISHI','NISSAN','PONTIAC',
				 'RAM','SATURN','SCION','SMART','SUBARU','SUZUKI','TOYOTA',
				 'VOLKSWAGEN');
%let Luxury=('ACURA','ALFA ROMEO','AUDI','B M W',
			 'GENESIS','HUMMER','INFINITI','JAGUAR','LAND ROVER',
			'LEXUS', 'MERCEDES-BENZ','PORSCHE',
			'SAAB','VOLVO');
%let Exotic=('ASTON MARTIN','BENTLEY','FERRARI','MASERATI','ROLLSROYCE');

%macro getEligibility();
	%let currentyear=%sysfunc(today(), year4.);
	%put &=currentyear.;
	proc sql;
		create table eligibility as
		select DisplayName as MAKE,
		CurrentYearID as CurrentYear,
		EligibleYears as EligibleYear
		from EDWVIMS.CPOeligibility
		order by MAKE
		;
		
		insert into work.eligibility
        values("Bentley", &currentyear., 10)
        values("Ferrari", &currentyear., 14);
	quit;
	
	data mmrIn.cpoeligibility;
		set eligibility;
		StartYear=CurrentYear-EligibleYear+1;
	run;
		
%mend;


%macro getCPOdata_ImpliedSold(EditionDate);
/*Get IMPLIED SOLD Listings*/
	proc sql;
		select count(*) into :iscount
		from SNOWVMA.vma_valmsold_used
		;
	quit;
	
	%put &iscount;
	
	%if &iscount>1000 %then %do;
		proc sql;
		create table mmrIn.cpois as
		select mid,
		substr(mid, 1, 11) as MID11,
		substr(MID, 1, 7) as MID7,
		substr(MID, 5, 7) as makemodel,
		substr(MID, 1, 4) as MID4,
		input(model_year, 4.) as year,
    	input(substr(mid,5,3),8.) as makeid, 
    	input(substr(mid,8,4),8.) as modelid,
    	a.MAKE as Make1, b.MAKE as Make2,
		lastseendate as sdtesl,
		list_price as sslepr,
    	odometer as smiles,
    	certification,
    	case when certification ne '' then 'Y'
    	else 'N' end as CPO_FLG,
    	RMIprice
	
		from SNOWVMA.vma_valmsold_used a
		join mmrIn.cpoeligibility b on upper(compress(a.EMAKE))=upper(compress(b.MAKE))
		where is_valid_vin=1
		and new_used='U'
		and days_in_inventory<365
		and mid ne ''
		and RMIprice ne .
		and list_price ne .
		and list_price > 100
		and list_price <1000000
		and lastseendate<= &EditionDate
		and lastseendate>= &EditionDate-365
    	and input(model_year, 4.)>=(year(&EditionDate.)-b.EligibleYear+1)       
    	order by mid11
		;
		quit;
	
		data mmrIn.cpois;
		set mmrIn.cpois;
		format rmipct percent10.1;
		rmipct=sslepr/rmiprice;
		if rmipct>0.5 and rmipct<1.5;
		run;
	%end;
	

	proc sql;
		create table mid11s as
		select a.mid11,a.year,a.makeid,a.modelid,b.make,b.model,
			sum(1) as count
		from mmrIn.cpois a, mmrcal.calmidtable b
		where a.mid11=substr(b.mid,1,11)
		and b.goodprice ne .
		group by a.mid11,a.year,makeid,modelid,b.make,model
		order by a.mid11,a.year,makeid,modelid,b.make,model;
	quit;
	
	%GENERICMAKEMODEL  (mid11gmodel,mid11s,model,make);
	
	data mid11gmodel;
		set mid11gmodel;
		if gmake='HYUANDAI' then do;
			gmake = 'HYUNDAI';
		end;
	run;
	
	proc sort data=mmrIn.cpois;
		by mid11;
	run;
	
	data mmrIn.cpois (keep= mid mid11 mid7 makemodel year makeid 
						modelid gmake gmodel sdtesl smiles sslepr rmiprice rmipct cpo_flg);
		merge mmrIn.cpois(in=s) mid11gmodel(in=p);
		by mid11;
		if s;
	run;
	
	data mmrIn.cpois;
		set mmrIn.cpois;
		if gmake in &nonluxury. then segment='NONLUXURY';
		else if gmake in &luxury. then segment='LUXURY';
		else if gmake in &exotic. then segment='EXOTIC';
	run;


%mend;

%macro getCPO_IS_YMM();
	/*Year Make Model Level*/
	proc sort data=mmrIn.cpois;
		by year gmake gmodel CPO_FLG;
	run;
	
	PROC GLM DATA=mmrIn.cpois noprint ;
		BY year gmake gmodel CPO_FLG;
		MODEL sslepr=RMIprice / solution;
		OUTPUT out=regcpois p=predict r=residual rstudent=rstudent student=student;
	RUN;
	
	data mmrIn.cpois1;
	merge mmrIn.cpois regcpois;
	if abs(rstudent)<=&maxRstu.;
	run;
	
	Proc Sql;
		create table cpois_MID11 as 
		select distinct year, gmake, gmodel, CPO_FLG, 
		sum(1) as Samplesize, 
		avg(RMIprice) as avgUVR,
		avg(sslepr) as avgSalePrice,
		sum(sslepr)/sum(RMIprice) as cpoPct
		from mmrIn.cpois
		where gmake ne ''
		and gmodel ne ''
		group by year, gmake, gmodel, CPO_FLG
		order by gmake, gmodel, year, CPO_FLG
		;
	quit;
	
	proc transpose data=cpois_MID11 out=mid11_wide prefix=cpo;
    by gmake gmodel year;
    id cpo_flg;
    var samplesize AvgUVR AvgSalePrice cpopct;
	run;
	
	data mid11;
		set mid11_wide;
		where _NAME_='Samplesize' and CPOY>&GoodSample.;
	run;
	
	proc sql;
		create table mid11_salepricediff as
		select a.gmake, a.gmodel, a.year, a.CPOY as CPOAvgPrice,
		a.CPON as nonCPOAVgPrice,
		a.CPOY - a.CPON as mid11_spdiff, b.CPOY as samplesize
		from mid11_wide a
		join mid11 b on a.year=b.year and a.gmake=b.gmake and a.gmodel=b.gmodel
		where a._NAME_='avgSalePrice'
		order by gmake, gmodel, year
		;
	quit;
		
	proc sql;
		create table mid11_cporet as
		select a.gmake, a.gmodel, a.year,
		a.CPOY/a.CPON as mid11_cporet
		from mid11_wide a
		join mid11 b on a.year=b.year and a.gmake=b.gmake and a.gmodel=b.gmodel
		where a._NAME_='cpoPct'
		order by gmake, gmodel, year
		;
	quit;
	
	proc sql;
		create table mid11_avgUVR as
		select a.gmake, a.gmodel, a.year,
		a.CPON as avgUVR_CPON
		from mid11_wide a
		join mid11 b on a.year=b.year and a.gmake=b.gmake and a.gmodel=b.gmodel
		where a._NAME_='avgUVR'
		order by gmake, gmodel, year
		;
	quit;
	
	data mid11_wise;
		merge mid11_salepricediff mid11_cporet mid11_avgUVR;
		by gmake gmodel year;
	run;
	
	data mmrCal.mid11_CPO_values;
		set mid11_wise;
		CPOValue = (mid11_cporet-1)*avgUVR_CPON;
		
		if gmake in &nonluxury. and CPOValue>&cpoupper2. then CPOValue=.;
		else if gmake in &nonluxury. and CPOValue<&cpolower2. then CPOValue=.;
		else if gmake in &luxury. and CPOValue>&cpoupper1. then CPOValue=.;
		else if gmake in &luxury. and CPOValue<&cpolower1. then CPOValue=.;
		else if gmake in &exotic. and CPOValue>&cpoupper1. then CPOValue=.;
		else if gmake in &exotic. and CPOValue<&cpolower1. then CPOValue=.;
		
		if gmake in &nonluxury. and mid11_spdiff>&cpoupper2. then mid11_spdiff=.;
		else if gmake in &nonluxury. and mid11_spdiff<&cpolower2. then mid11_spdiff=.;
		else if gmake in &luxury. and mid11_spdiff>&cpoupper1. then mid11_spdiff=.;
		else if gmake in &luxury. and mid11_spdiff<&cpolower1. then mid11_spdiff=.;
		else if gmake in &exotic. and mid11_spdiff>&cpoupper1. then mid11_spdiff=.;
		else if gmake in &exotic. and mid11_spdiff<&cpolower1. then mid11_spdiff=.;
				
		CPOvalue_final=coalesce(CPOvalue, mid11_spdiff);
		if CPOValue_final = . then samplesize=.;
		if CPOValue_final = . then mid11_cporet=.;
		if CPOValue_final = . then CPOAvgPrice=.;
		if CPOValue_final = . then nonCPOAvgPrice=.;
	run;
	
	proc sort data=mmrCal.mid11_CPO_values;
		by gmake gmodel year;
	run;
	
%mend;

%macro getCPO_IS_MM();
	/*Make Model Level*/
	proc sql;
		create table MMavg as
		select gmake, gmodel, avg(CPOValue_final) as mmAvg
		from mmrCal.mid11_CPO_values
		where CPOValue_final ne .
		group by gmake, gmodel
		order by gmake, gmodel
		;
	quit;
	
	proc sort data=mmrIn.cpois;
		by gmake gmodel CPO_FLG;
	run;
	
	PROC GLM DATA=mmrIn.cpois noprint ;
		BY gmake gmodel CPO_FLG;
		MODEL sslepr=RMIprice / solution;
		OUTPUT out=regcpois p=predict r=residual rstudent=rstudent student=student;
	RUN;
	
	data mmrIn.cpois1;
	merge mmrIn.cpois regcpois;
	if abs(rstudent)<=&maxRstu.;
	run;
	
	Proc Sql;
		create table cpois_MM as 
		select distinct gmake, gmodel, CPO_FLG, 
		sum(1) as Samplesize, 
		avg(RMIprice) as avgUVR,
		avg(sslepr) as avgSalePrice,
		sum(sslepr)/sum(RMIprice) as cpoPct
		from mmrIn.cpois
		where gmake ne ''
		and gmodel ne ''
		group by gmake, gmodel, CPO_FLG
		order by gmake, gmodel, CPO_FLG
		;
	quit;
	
	proc transpose data=cpois_MM out=MM_wide prefix=cpo;
    by gmake gmodel;
    id cpo_flg;
    var samplesize AvgUVR AvgSalePrice cpopct;
	run;
	
	data MM;
		set MM_wide;
		where _NAME_='Samplesize' and CPOY>&GoodSample.;
	run;
	
	proc sql;
		create table MM_salepricediff as
		select a.gmake, a.gmodel, a.CPOY as CPOAvgPrice,
		a.CPON as nonCPOAVgPrice,
		a.CPOY - a.CPON as mid11_spdiff, b.CPOY as samplesize
		from MM_wide a
		join MM b on a.gmake=b.gmake and a.gmodel=b.gmodel
		where a._NAME_='avgSalePrice'
		order by gmake, gmodel
		;
	quit;
		
	proc sql;
		create table MM_cporet as
		select a.gmake, a.gmodel,
		a.CPOY/a.CPON as MM_cporet
		from MM_wide a
		join MM b on a.gmake=b.gmake and a.gmodel=b.gmodel
		where a._NAME_='cpoPct'
		order by gmake, gmodel
		;
	quit;
	
	proc sql;
		create table MM_avgUVR as
		select a.gmake, a.gmodel,
		a.CPON as avgUVR_CPON
		from MM_wide a
		join MM b on a.gmake=b.gmake and a.gmodel=b.gmodel
		where a._NAME_='avgUVR'
		order by gmake, gmodel
		;
	quit;
	
	data MM_wise;
		merge MM_salepricediff MM_cporet MM_avgUVR;
		by gmake gmodel;
	run;
	
	proc sql;
		create table MM_wise as
		select *
		from MM_wise a
		left join MMavg b on a.gmake=b.gmake and a.gmodel=b.gmodel
		;
	quit;
	
	
	data mmrCal.MM_CPO_values;
		set MM_wise;
		CPOValue = (MM_cporet-1)*avgUVR_CPON;
		
		if gmake in &nonluxury. and CPOValue>&cpoupper2. then CPOValue=.;
		else if gmake in &nonluxury. and CPOValue<&cpolower2. then CPOValue=.;
		else if gmake in &luxury. and CPOValue>&cpoupper1. then CPOValue=.;
		else if gmake in &luxury. and CPOValue<&cpolower1. then CPOValue=.;
		else if gmake in &exotic. and CPOValue>&cpoupper1. then CPOValue=.;
		else if gmake in &exotic. and CPOValue<&cpolower1. then CPOValue=.;
		
		if gmake in &nonluxury. and mmAvg>&cpoupper2. then mmAvg=.;
		else if gmake in &nonluxury. and mmAvg<&cpolower2. then mmAvg=.;
		else if gmake in &luxury. and mmAvg>&cpoupper1. then mmAvg=.;
		else if gmake in &luxury. and mmAvg<&cpolower1. then mmAvg=.;
		else if gmake in &exotic. and mmAvg>&cpoupper1. then mmAvg=.;
		else if gmake in &exotic. and mmAvg<&cpolower1. then mmAvg=.;
				
		CPOvalue_final=coalesce(CPOvalue, mmAvg);
		if CPOValue_final = . then samplesize=.;
		if CPOValue_final = . then MM_cporet=.;
		if CPOValue_final = . then CPOAvgPrice=.;
		if CPOValue_final = . then nonCPOAvgPrice=.;
	run;
	
	proc sort data=mmrCal.MM_CPO_values;
		by gmake gmodel;
	run;
%mend;

%macro getCPO_IS_Make();
	
	/*Make Level*/
	proc sql;
		create table Makeavg as
		select gmake, avg(CPOValue_final) as makeAvg
		from mmrCal.MM_CPO_values
		where CPOValue_final ne .
		group by gmake
		order by gmake
		;
	quit;
	
	proc sort data=mmrIn.cpois;
		by gmake CPO_FLG;
	run;
	
	PROC GLM DATA=mmrIn.cpois noprint ;
		BY gmake CPO_FLG;
		MODEL sslepr=RMIprice / solution;
		OUTPUT out=regcpois p=predict r=residual rstudent=rstudent student=student;
	RUN;
	
	data mmrIn.cpois1;
	merge mmrIn.cpois regcpois;
	if abs(rstudent)<=&maxRstu.;
	run;
	
	Proc Sql;
		create table cpois_Make as 
		select distinct gmake, CPO_FLG, 
		sum(1) as Samplesize, 
		avg(RMIprice) as avgUVR,
		avg(sslepr) as avgSalePrice,
		sum(sslepr)/sum(RMIprice) as cpoPct
		from mmrIn.cpois
		where gmake ne ''
		group by gmake, CPO_FLG
		order by gmake, CPO_FLG
		;
	quit;
	
	proc transpose data=cpois_Make out=Make_wide prefix=cpo;
    by gmake;
    id cpo_flg;
    var samplesize AvgUVR AvgSalePrice cpopct;
	run;
	
	data Make;
		set Make_wide;
		where _NAME_='Samplesize' and CPOY>&GoodSample.;
	run;
	
	proc sql;
		create table Make_salepricediff as
		select a.gmake, a.CPOY as CPOAvgPrice,
		a.CPON as nonCPOAVgPrice,
		a.CPOY - a.CPON as Make_spdiff, b.CPOY as samplesize
		from Make_wide a
		join Make b on a.gmake=b.gmake 
		where a._NAME_='avgSalePrice'
		order by gmake
		;
	quit;
		
	proc sql;
		create table Make_cporet as
		select a.gmake,
		a.CPOY/a.CPON as Make_cporet
		from Make_wide a
		join Make b on a.gmake=b.gmake 
		where a._NAME_='cpoPct'
		order by gmake
		;
	quit;
	
	proc sql;
		create table Make_avgUVR as
		select a.gmake, 
		a.CPON as avgUVR_CPON
		from Make_wide a
		join Make b on a.gmake=b.gmake 
		where a._NAME_='avgUVR'
		order by gmake
		;
	quit;
	
	data Make_wise;
		merge Make_salepricediff Make_cporet Make_avgUVR;
		by gmake;
	run;
	
	proc sql;
		create table Make_wise as
		select *
		from Make_wise a
		left join Makeavg b on a.gmake=b.gmake 
		;
	quit;
	
	data mmrCal.Make_CPO_values;
		set Make_wise;
		CPOValue = (Make_cporet-1)*avgUVR_CPON;
		
		if gmake in &nonluxury. and CPOValue>&cpoupper2. then CPOValue=.;
		else if gmake in &nonluxury. and CPOValue<&cpolower2. then CPOValue=.;
		else if gmake in &luxury. and CPOValue>&cpoupper1. then CPOValue=.;
		else if gmake in &luxury. and CPOValue<&cpolower1. then CPOValue=.;
		else if gmake in &exotic. and CPOValue>&cpoupper1. then CPOValue=.;
		else if gmake in &exotic. and CPOValue<&cpolower1. then CPOValue=.;
		
		if gmake in &nonluxury. and makeAvg>&cpoupper2. then makeAvg=.;
		else if gmake in &nonluxury. and makeAvg<&cpolower2. then makeAvg=.;
		else if gmake in &luxury. and makeAvg>&cpoupper1. then makeAvg=.;
		else if gmake in &luxury. and makeAvg<&cpolower1. then makeAvg=.;
		else if gmake in &exotic. and makeAvg>&cpoupper1. then makeAvg=.;
		else if gmake in &exotic. and makeAvg<&cpolower1. then makeAvg=.;
				
		CPOvalue_final=coalesce(makeAvg, CPOValue);
		if CPOValue_final = . then samplesize=.;
		if CPOValue_final = . then Make_cporet=.;
		if CPOValue_final = . then CPOAvgPrice=.;
		if CPOValue_final = . then nonCPOAvgPrice=.;
		
	run;
	
	proc sort data=mmrCal.Make_CPO_values;
		by gmake;
	run;
	
%mend;

%macro getCPO_IS_Seg();
	
	data mmrCal.Make_CPO_values;
		set mmrCal.Make_CPO_values;
		if gmake in &nonluxury. then segment='NONLUXURY';
		else if gmake in &luxury. then segment='LUXURY';
		else if gmake in &exotic. then segment='EXOTIC';
	run;
	
	proc sort data=mmrIn.cpois;
		by segment CPO_FLG;
	run;
	
	
	Proc Sql;
		create table cpois_Seg as 
		select distinct segment, CPO_FLG, 
		sum(1) as Samplesize, 
		avg(RMIprice) as avgUVR,
		avg(sslepr) as avgSalePrice,
		sum(sslepr)/sum(RMIprice) as cpoPct
		from mmrIn.cpois
		where segment ne ''
		group by segment, CPO_FLG
		order by segment, CPO_FLG
		;
	quit;
	
	proc transpose data=cpois_seg out=Seg_wide prefix=cpo;
    by segment;
    id cpo_flg;
    var samplesize AvgUVR AvgSalePrice cpopct;
	run;
	
	data segment;
		set seg_wide;
		where _NAME_='Samplesize' and CPOY>&GoodSample.;
	run;
	
	proc sql;
		create table Seg_salepricediff as
		select a.segment, a.CPOY as CPOAvgPrice,
		a.CPON as nonCPOAVgPrice,
		b.CPOY as samplesize
		from seg_wide a
		join segment b on a.segment=b.segment
		where a._NAME_='avgSalePrice'
		order by segment
		;
	quit;
		
	proc sql;
		create table seg_cporet as
		select a.segment,
		a.CPOY/a.CPON as seg_cporet
		from seg_wide a
		join Segment b on a.segment=b.segment
		where a._NAME_='cpoPct'
		order by segment
		;
	quit;
	
	proc sql;
	create table Seg_CPO_Values as
	select segment,
	avg(CPOValue_final) as CPOValue_final
	from mmrCal.Make_CPO_values
	group by segment;
	quit;
	
	data mmrCal.Seg_CPO_Values;
		merge seg_salepricediff seg_cporet Seg_CPO_Values;
		by segment;
	run;
	
%mend;

%macro getCPO_ImpliedSold();
	%getCPO_IS_YMM;
	%getCPO_IS_MM;
	%getCPO_IS_Make;
	%getCPO_IS_Seg;
%mend;

%macro get_CPO_Final();
	proc sql;
		select sum(sslepr)/sum(RMIprice) into :isfactor
		from mmrIn.cpois
		;
	quit;

	proc sql;
		create table template0 as
		select distinct a.mid,a.year,a.make,a.model
		from mmrCal.calmidtable a
		join mmrIn.cpoeligibility b on upper(compress(a.make))=upper(compress(b.MAKE))
		where a.YEAR>=(year(&EditionDate.) - b.EligibleYear + 1)
		and a.goodprice ne .
		order by a.make, a.model, a.year
		;
	quit;
	
	%GENERICMAKEMODEL  (template1,template0,model,make);
	
	data template1;
		set template1;
		if gmake='HYUANDAI' then do;
			gmake = 'HYUNDAI';
		end;
	run;
	
	data template1;
		set template1;
		if gmake in &nonluxury. then segment='NONLUXURY';
		else if gmake in &luxury. then segment='LUXURY';
		else if gmake in &exotic. then segment='EXOTIC';
	run;
	
	proc sql;
		create table mmrCal.MID_CPO_Values as
		select distinct a.MID, a.Year, a.Make, a.Model, a.GMAKE, a.GMODEL, a.segment,
		c.samplesize as N_MID11, c.CPOValue_final/&isfactor. as CPO_MID11,
		c.CPOAvgPrice as MID11_CPOSP, c.nonCPOAvgPrice as MID11_NonCPOSP,
		c.mid11_cporet,
		d.samplesize as N_MM, d.CPOValue_final/&isfactor. as CPO_MM,
		d.CPOAvgPrice as MM_CPOSP, d.nonCPOAvgPrice as MM_NonCPOSP,
		d.MM_cporet,
		e.samplesize as N_Make, e.CPOValue_final/&isfactor. as CPO_Make,
		e.CPOAvgPrice as Make_CPOSP, e.nonCPOAvgPrice as Make_NonCPOSP,
		e.Make_cporet,
		f.samplesize as N_Seg, f.CPOValue_final/&isfactor. as CPO_Seg,
		f.CPOAvgPrice as Seg_CPOSP, f.nonCPOAvgPrice as Seg_NonCPOSP,
		f.seg_cporet,
		g.FINAL_CPO_CERTIFICATION_COST as CPO_CERTIFICATION_COST
		
		from template1 a
		left join mmrCal.MID11_CPO_VALUES c on c.year=a.year and c.gmake=a.gmake and c.gmodel=a.gmodel
		left join mmrCal.MM_CPO_VALUES d on d.gmake=a.gmake and d.gmodel=a.gmodel
		left join mmrCal.Make_CPO_VALUES e on e.gmake=a.gmake
		left join mmrCal.seg_CPO_VALUES f on a.segment=f.segment
		left join SNOW.UVR_VALOPS_CPO_COST g on upper(compress(a.gmake))=upper(compress(g.GENERIC_MAKE)) and upper(compress(a.gmodel))=upper(compress(g.GENERIC_MODEL))
		where g.CPO_EXCLUSION_FLAG='0'
		;
	quit;
	
	data mmrCal.MID_CPO_retail_Final (keep=MID year GMAKE GMODEL CPOAvgPrice nonCPOAvgPrice
											CPOsamplesize CPORet CPOValue_DS CPO_CERTIFICATION_COST 
											CPOValue_UCFPP Level);
		set mmrCal.MID_CPO_VALUES ;
		
		if CPO_MID11 ne . then Level='MID11';
		else if CPO_MM ne . then Level='MM';
		else if CPO_Make ne . then level='Make';
		else if CPO_Seg ne . then Level='Seg';
		else Level='';
		
		CPOSampleSize=coalesce(N_MID11, N_MM, N_Make, N_Seg);
		CPOValue_DS=coalesce(CPO_MID11, CPO_MM, CPO_Make, CPO_Seg);
		CPOValue_UCFPP=max(CPOValue_DS, CPO_CERTIFICATION_COST);
		CPOAvgPrice=coalesce(MID11_CPOSP, MM_CPOSP, Make_CPOSP,Seg_CPOSP);
		nonCPOAvgPrice=coalesce(MID11_NonCPOSP, MM_NonCPOSP, Make_NonCPOSP,Seg_NonCPOSP);
		CPORet=coalesce(MID11_cporet, MM_cporet, Make_cporet,Seg_cporet);
	run;
	
	proc sql;
		create table mmrCal.MID_CPO_listing_Final as
		select a.MID, a.year, a.GMAKE, a.GMODEL, a.CPOAvgPrice, 
		a.nonCPOAvgPrice,a.CPOsamplesize, a.CPORet,
		a.CPOValue_DS*b.listingfactor as CPOValue_TLP_DS,
		a.CPOValue_UCFPP*b.listingfactor as CPOValue_TLP, a.level
		from mmrCal.MID_CPO_retail_Final a
		join mmrCal.listingfactors_final b on a.mid=b.mid
		;
	quit;		
	
	proc sql;
		create table mmrCal.YMM_CPO_Values as
		select distinct year, GMAKE, GMODEL, segment, 
		N_MID11, CPO_MID11, MID11_CPOSP, MID11_NonCPOSP, mid11_cporet,
		N_MM, CPO_MM, MM_CPOSP, MM_NonCPOSP, MM_cporet,
		N_Make, CPO_Make,Make_CPOSP, Make_NonCPOSP, Make_cporet,
		N_Seg, CPO_Seg,Seg_CPOSP, Seg_NonCPOSP, Seg_cporet,
		CPO_CERTIFICATION_COST 
		from mmrCal.MID_CPO_Values
		;
	quit;
	
	data mmrCal.YMM_CPO_Values_Final (keep=year GMAKE GMODEL CPOAvgPrice nonCPOAvgPrice
											CPOsamplesize CPORet CPOValue_DS CPOValue Level);
		set mmrCal.YMM_CPO_VALUES ;
		
		if CPO_MID11 ne . then Level='MID11';
		else if CPO_MM ne . then Level='MM';
		else if CPO_Make ne . then level='Make';
		else if CPO_Seg ne . then Level='Seg';
		else Level='';
		
		CPOSampleSize=coalesce(N_MID11, N_MM, N_Make, N_Seg);
		CPOValue_DS=coalesce(CPO_MID11, CPO_MM, CPO_Make, CPO_Seg);
		CPOValue=max(CPOValue_DS, CPO_CERTIFICATION_COST);
		CPOAvgPrice=coalesce(MID11_CPOSP, MM_CPOSP, Make_CPOSP,Seg_CPOSP);
		nonCPOAvgPrice=coalesce(MID11_NonCPOSP, MM_NonCPOSP, Make_NonCPOSP,Seg_NonCPOSP);
		CPORet=coalesce(MID11_cporet, MM_cporet, Make_cporet,Seg_cporet);
	run;
	
	proc sort data=mmrCal.YMM_CPO_Values_Final;
		by GMAKE GMODEL year;
	run;
%mend;


%macro publish_CPOvalues(EditionDate);
	%getEligibility();
	%getCPOdata_ImpliedSold(&EditionDate.);
	%getCPO_ImpliedSold();
	%get_CPO_Final();
	
	proc sql;
	create table mmrout.UVRCPOValue as
	select input(substr(a.mid,1,4),4.) as year,
	input(substr(a.mid,5,3),8.) as makeid, 
    input(substr(a.mid,8,4),8.) as modelid,
    input(substr(a.mid,12,4),8.) as bodyid,
    round(CPOValue_UCFPP, 25) as CPOValue_UCFPP
	from mmrCal.MID_CPO_retail_Final a
	;
	quit;
	
	proc sql;
	create table mmrout.UVLCPOValue as
	select input(substr(a.mid,1,4),4.) as year,
	input(substr(a.mid,5,3),8.) as makeid, 
    input(substr(a.mid,8,4),8.) as modelid,
    input(substr(a.mid,12,4),8.) as bodyid,
    round(CPOValue_TLP, 25) as CPOValue_TLP
	from mmrCal.MID_CPO_listing_Final a
	;
	quit;
	
	proc datasets library=work kill nolist;
	run;
	quit;
	
	proc datasets lib=mmrIn nolist;
 	delete cpout cpois1;
 	run;
	quit;
	
%mend;