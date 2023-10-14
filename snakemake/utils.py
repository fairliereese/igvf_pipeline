import pandas as pd
import anndata
import scanpy as sc
# import scrublet as scr

from bc_utils import *

def get_bc1(text):
    return text[-8:]

def get_bc2(text):
    return text[8:16]

def get_bc3(text):
    return text[:8]

# TODO hopefully won't need this at some pt
def get_genotype_path_dict():
    d = {"/home/delaney/igvf/references/PRJNA923323/Mus_musculus_129s1svimj.fa.gz": "129S1J",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_casteij.fa.gz": "CASTJ",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_aj.fa.gz": "AJ",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_nodshiltj.fa.gz": "NODJ",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_nzohlltj.fa.gz": "NZOJ",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_pwkphj.fa.gz": "PWKJ",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_wsbeij.fa.gz": "WSBJ",
        "/home/delaney/igvf/references/PRJNA923323/Mus_musculus_c57bl6j.fa.gz": "B6J"}

    return d

def rename_klue_genotype_cols(adata):
    """
    """
    d = get_genotype_path_dict()
    adata.var['genotype'] = adata.var.gene_name.map(d)
    adata.var.set_index('genotype', inplace=True)
    return adata

def add_meta_filter(adata,
                     cgg,
                     wc,
                     bc_df,
                     kit,
                     chemistry,
                     klue,
                     sample_df,
                     min_counts,
                     ofile):
    """
    Add gene names to the kallisto output.
    Very initial filtering on min_counts.
    """
    adata = sc.read(adata)
    adata.obs.reset_index(inplace=True)
    adata.obs.columns = ['bc']

    adata.obs['bc1_sequence'] = adata.obs['bc'].apply(get_bc1)
    adata.obs['bc2_sequence'] = adata.obs['bc'].apply(get_bc2)
    adata.obs['bc3_sequence'] = adata.obs['bc'].apply(get_bc3)

    adata.var.reset_index(inplace=True)
    adata.var.columns = ['gene_name']
    names = pd.read_csv(cgg, sep="\t", header = None)
    names.columns = ['gene_id']
    adata.var['gene_id'] = names['gene_id']

    adata.obs['subpool'] = wc.subpool

    sc.pp.filter_cells(adata, min_counts=min_counts, inplace=True)

    # merge in bc metadata
    temp = bc_df.copy(deep=True)
    temp = temp[['bc1_dt', 'well']].rename({'bc1_dt': 'bc1_sequence',
                                             'well': 'bc1_well'}, axis=1)
    adata.obs = adata.obs.merge(temp, how='left', on='bc1_sequence')

    # merge in other bc information
    for bc in [2,3]:
        bc_name = f'bc{bc}'
        seq_col = f'bc{bc}_sequence'
        well_col = f'bc{bc}_well'
        bc_df = get_bcs(bc, kit, chemistry)
        bc_df.rename({'well': well_col,
                      bc_name: seq_col}, axis=1, inplace=True)
        adata.obs = adata.obs.merge(bc_df, how='left', on=seq_col)

    # merge in w/ sample-level metadata
    temp = sample_df.copy(deep=True)
    temp = temp.loc[(sample_df.plate==wc.plate)]
    adata.obs = adata.obs.merge(temp, how='left', on='bc1_well')
    adata.var.set_index('gene_id', inplace=True)

    # make all object columns string columns
    for c in adata.obs.columns:
        if pd.api.types.is_object_dtype(adata.obs[c].dtype):
            adata.obs[c] = adata.obs[c].fillna('NA')

    # create new index for each cell
    adata.obs['cellID'] = adata.obs['bc1_well']+'_'+\
        adata.obs['bc2_well']+'_'+\
        adata.obs['bc3_well']+'_'+\
        adata.obs['subpool']+'_'+\
        adata.obs['plate']
    adata.obs.reset_index(drop=True)

    # make sure these are unique + set as index
    assert len(adata.obs.index) == len(adata.obs.cellID.unique().tolist())
    adata.obs.set_index('cellID', inplace=True)

    # remove non-multiplexed cells if from klue
    if klue:
        inds = adata.obs.loc[adata.obs.well_type=='Multiplexed'].index
        adata = adata[inds, :].copy()
        # TODO
        adata = rename_klue_genotype_cols(adata)

    adata.write(ofile)

def make_subpool_sample_adata(infile, wc, ofile):
    adata = sc.read(infile)
    inds = []

    # filter on sample
    # TODO sample will be combo of {tissue}_{genotype}_{sex}_{rep}
    inds += adata.obs.loc[adata.obs['Mouse_Tissue_ID']==wc.sample].index.tolist()

    adata = adata[inds, :].copy()

    adata.write(ofile)

def run_scrublet(infile,
                 n_pcs,
                 min_counts,
                 min_cells,
                 min_gene_variability_pctl,
                 ofile):
    adata = sc.read(infile)

    # if number of cells is very low, don't call doublets, fill in
    if adata.X.shape[0] <= n_pcs:
        adata.obs['doublet_scores'] = 0

    # number of cells has to be more than number of PCs
    elif adata.X.shape[0] > 30:
        scrub = scr.Scrublet(adata.X)
        doublet_scores, predicted_doublets = scrub.scrub_doublets(min_counts=min_counts,
                                                                  min_cells=min_cells,
                                                                  min_gene_variability_pctl=min_gene_variability_pctl,
                                                                  n_prin_comps=n_pcs)
        adata.obs['doublet_scores'] = doublet_scores

    adata.write(ofile)

def concat_adatas(adatas, ofile):
    for i, f in enumerate(adatas):
        if i == 0:
            adata = sc.read(f)
        else:
            temp = sc.read(f)

            temp.obs.reset_index(inplace=True)
            # if 'A10_A7_C3_Sublibrary_2_igvf_013' in temp.obs.cellID.tolist():
            #     import pdb; pdb.set_trace()
            temp.obs.set_index('cellID', inplace=True)
            adata = adata.concatenate(temp,
                        join='outer',
                        index_unique=None)
            adata.obs.reset_index(inplace=True)
            # if len(adata.obs.index) != len(adata.obs.cellID.unique().tolist()):
            #     import pdb; pdb.set_trace()
            adata.obs.set_index('cellID', inplace=True)

    adata.write(ofile)
