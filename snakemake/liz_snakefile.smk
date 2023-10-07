import pandas as pd

p = os.path.dirname(os.getcwd())
sys.path.append(p)

from utils import *
from sm_utils import *
from bc_utils import *


configfile: 'configs/config.yml'

# variables to change (again these could go in
# a future analysis spec)
config_tsv = 'configs/test_3.tsv'
sample_csv = 'configs/sample_metadata.csv'
kit = 'WT_mega'
chemistry = 'v2'
first_min_counts = 500

# read in config / analysis spec
df = parse_config(config_tsv)
bc_df = get_bc1_matches(kit, chemistry)
sample_df = pd.read_csv(sample_csv)

wildcard_constraints:
    plate='|'.join([re.escape(x) for x in df.plate.tolist()]),
    subpool='|'.join([re.escape(x) for x in df.subpool.tolist()]),
    lane='|'.join([re.escape(x) for x in df.lane.tolist()]),
    sample='|'.join([re.escape(x) for x in sample_df.Mouse_Tissue_ID.tolist()]),
    tissue='|'.join([re.escape(x) for x in sample_df.Tissue.tolist()]),

def get_subset_tissues(df, sample_df):
    temp = df.merge(sample_df, on='plate', how='inner')
    tissues = temp.Tissue.unique().tolist()
    return tissues

def get_sample_subpool_files(df, sample_df, cfg_entry):
    plates = df.plate.unique().tolist()
    subpools = df.subpool.unique().tolist()

    # get samples from the sample_df that
    # correspond to this experiment
    temp = sample_df.copy(deep=True)
    temp = temp.loc[temp.plate.isin(plates)]
    samples = temp.Mouse_Tissue_ID.unique().tolist()

    adatas = expand(cfg_entry,
           plate=plates,
           sample=samples,
           subpool=subpools)
    return adatas

rule all:
    input:
        # get_sample_subpool_files(df, sample_df, config['scrublet']['scrub_adata'])
        expand(config['tissue']['adata'],
               tissue=get_subset_tissues(df, sample_df))
        # expand(config['filter']['adata'],
        #        zip,
        #        plate=df.plate.tolist(),
        #        subpool=df.subpool.tolist())

###############################
### Ref download and generation
###############################

rule dl:
   resources:
       mem_gb = 4,
       threads = 1
   shell:
       "wget -O {output.out} {params.link}"

use rule dl as dl_annot with:
    params:
        link = config['ref']['annot_link']
    output:
        out = config['ref']['annot']

use rule dl as dl_fa with:
    params:
        link = config['ref']['fa_link']
    output:
        out = config['ref']['fa']

rule kallisto_ind:
    input:
        annot = config['ref']['annot'],
        fa = config['ref']['fa']
    conda:
        "hpc3sc"
    resources:
        mem_gb = 16,
        threads = 8
    output:
        t2g = config['ref']['kallisto']['t2g'],
        ind = config['ref']['kallisto']['ind'],
        fa = config['ref']['kallisto']['fa']
    shell:
        """
        kb ref \
            -i {output.ind} \
            -g {output.t2g} \
            -f1 {output.fa} \
            {input.fa} \
            {input.annot}
        """


##################################

rule symlink_fastq_r1:
    params:
        fastq = lambda wc:get_df_info(wc, df, 'fastq')
    resources:
        mem_gb = 4,
        threads = 1
    output:
        fastq = config['raw']['r1_fastq']
    shell:
        """
        ln -s {params.fastq} {output.fastq}
        """

rule symlink_fastq_r2:
    params:
        fastq = lambda wc:get_df_info(wc, df, 'r2_fastq')
    resources:
        mem_gb = 4,
        threads = 1
    output:
        fastq = config['raw']['r2_fastq']
    shell:
        """
        ln -s {params.fastq} {output.fastq}
        """

rule kallisto:
    input:
        r1_fastq = lambda wc:get_subpool_fastqs(wc, df, config, how='list', read='R1'),
        r2_fastq = lambda wc:get_subpool_fastqs(wc, df, config, how='list', read='R2')
    conda:
        "hpc3sc"
    params:
        bc1_map = config['ref']['bc1_map'],
        barcodes = config['ref']['barcodes'],
        t2g = config['ref']['kallisto']['t2g'],
        ind = config['ref']['kallisto']['ind'],
        c1 = config['ref']['c1'],
        c2 = config['ref']['c2'],
        fastq_str = lambda wc:get_subpool_fastqs(wc, df, config, how='str'),
        odir = config['kallisto']['cgb'].split('counts_unfiltered_modified/')[0]
    resources:
        mem_gb = 250,
        threads = 24
    output:
        config['kallisto']['cgb'],
        config['kallisto']['cggn'],
        config['kallisto']['cgg'],
        config['kallisto']['cgn']
    shell:
        """
        kb count \
            --h5ad \
        	--gene-names \
        	--sum=nucleus \
        	--strand=forward \
        	-r {params.bc1_map} \
        	-w {params.barcodes} \
        	--workflow=nac \
        	-g {params.t2g} \
        	-x SPLIT-SEQ \
        	-i {params.ind} \
        	-t {resources.threads} \
        	-o {params.odir} \
        	-c1 {params.c1} \
        	-c2 {params.c2} \
        	{params.fastq_str}
        """

rule make_subpool_adata:
    input:
        adata = config['kallisto']['adata'],
        cgg = config['kallisto']['cgg']
    params:
        min_counts = first_min_counts
    resources:
        mem_gb = 128,
        threads = 4
    output:
        adata = config['filter']['adata']
    run:
        make_subpool_adata(input.adata,
                         input.cgg,
                         wildcards,
                         bc_df,
                         kit,
                         chemistry,
                         sample_df,
                         params.min_counts,
                         output.adata)


####################
###### Scrublet ####
####################
rule scrublet_make_adata:
    input:
        adata = config['filter']['adata']
    resources:
        mem_gb = 32,
        threads = 2
    output:
        adata = temporary(config['scrublet']['adata'])
    run:
        make_subpool_sample_adata(input.adata,
                                  wildcards,
                                  output.adata)


rule scrublet:
    input:
        adata = config['scrublet']['adata']
    params:
        n_pcs = 30,
        min_counts = 1,
        min_cells = 1,
        min_gene_variability_pctl = 85
    resources:
        mem_gb = 256,
        threads = 8
    output:
        adata = config['scrublet']['scrub_adata']
    run:
        run_scrublet(input.adata,
                     params.n_pcs,
                     params.min_counts,
                     params.min_cells,
                     params.min_gene_variability_pctl,
                     output.adata)


####################
### Combine adatas
###################

def get_tissue_adatas(df, sample_df, wc, cfg_entry):

    # limit to input tissue
    temp_sample = sample_df.copy(deep=True)
    temp_sample = temp_sample.loc[temp_sample.Tissue==wc.tissue]

    # merge this stuff in with the fastq df
    fastq_df = df.copy(deep=True)
    temp = fastq_df.merge(sample_df, on='plate', how='inner')

    # get the plate / subpool / sample info for this tissue
    plates = temp.plate.tolist()
    subpools = temp.subpool.tolist()
    samples = temp.Mouse_Tissue_ID.tolist()

    files = expand(cfg_entry,
           zip,
           plate=plates,
           sample=samples,
           subpool=subpools)

    return files

rule tissue_concat_adatas:
    input:
        adatas = lambda wc:get_tissue_adatas(df, sample_df, wc, config['scrublet']['scrub_adata'])
    resources:
        mem_gb = 256,
        threads = 2
    output:
        adata = config['tissue']['adata']
    run:
        concat_adatas(input.adatas, output.adata)
